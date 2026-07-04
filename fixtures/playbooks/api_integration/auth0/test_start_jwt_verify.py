#!/usr/bin/env python3
"""Offline unit tests for the auth0_login `start` step JWT signature verification.

noetl/ai-meta#169 — mirrors the Rust unit coverage in
`noetl/server` `src/handlers/auth_verify.rs` for the drive-path playbook.

The verification code under test is EXTRACTED FROM the shipped
`auth0_login.yaml` `start` step (no copy → no drift): the test loads the
playbook, pulls the step's `code`, execs it, and calls the resulting
functions.  RSA signing for the fixtures is done in pure stdlib with a
fixed throwaway keypair (below) so the test needs no PyJWT / cryptography —
matching the constraint that the shipped code is stdlib-only.

Run:  python3 test_start_jwt_verify.py     (exit 0 = all pass)
"""
import base64
import hashlib
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PLAYBOOK = os.path.join(HERE, "auth0_login.yaml")

# ── Fixed throwaway RSA-2048 keypair generated offline for THESE TESTS ONLY.
# Not a secret; guards nothing.  Lets us sign + verify without a live tenant.
# (mirrors the TEST_PRIV_PEM constant in auth_verify.rs)
N = 20918114652978382034319016340145344586298335398726391514057747945563282673765406834223048682512092134357384156619026276599428098752988405736875677182019840569390074416269793262079088425669155960618728460174525412881818112511328995720812654357606432162636016439635126838390007975977773957617611133707005623544196048987481680845286889191153785515902185190303526324256733909481442839154376469713409789463192460428498557380977337639988903114529085023104611631786505803312521522237266455621312324350571587208274213866495421952787895677585492274355714428924599097215080383619686884999498885029437946548717482913161312652017
E = 65537
D = 1480517491155228726767913656312681094092571047606578986495519536223740584437200964349048801651469236694031255786461897615186035919644425591810699736161237628837387432745890657890258200138339867911713565810451136421446103954770580689549254577380066765130951405393099101879427682020429749643854452350579757767496389482580039704940683924598948570996999119677335162594250392640624560759858095025953874911733817358112111665088511026521694641320366680973398894910080960737778312487099844952258831833041154695615186853308465389187243653253872888832702388313908864721016996265356908585898367277605355646965146374211630040083
N_B64U = "pbQRJR0UTw2vG4tYcZm3-_JryPEtWAjZHYOf2-_Da-tzcOUqVt5HbtqZCDruh88eyzGFGgnB4cC1ftwMbSf9Vw3F9sOXtssiHlbHRgU5zeR_ndHa--Q4XGZ3vsFVxy6FoXgafKbuU_N9B4268X-H6K2cpO6WP-iCxVbJ-M8BuBD85YKcvKbpPz0Cs77TQ_UrA0R_6frAOd2bdC03McG8F9PcPzlxf2RmjYvUFvKMkXGa86E5Cru7G9pPyVyFacEzdETXAnyZPRAkPNYu5xN5Fq1YzYJsREj_RK8rDzJBf52VGbF30GaIkahppz9ZMnMySfd8naQOoZlcmT2CyPrK8Q"
E_B64U = "AQAB"

KID = "test-key-1"
ISSUER_DOMAIN = "tenant.us.auth0.com"
ISSUER = f"https://{ISSUER_DOMAIN}/"

_SHA256_DIGEST_INFO = bytes([
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
    0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
])


def _b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def _rs256_sign(signing_input):
    k = (N.bit_length() + 7) // 8
    t = _SHA256_DIGEST_INFO + hashlib.sha256(signing_input).digest()
    em = b"\x00\x01" + (b"\xff" * (k - len(t) - 3)) + b"\x00" + t
    sig_int = pow(int.from_bytes(em, "big"), D, N)
    return sig_int.to_bytes(k, "big")


def make_token(claims, kid=KID, alg="RS256", sign=True):
    header = {"alg": alg, "typ": "JWT"}
    if kid is not None:
        header["kid"] = kid
    h = _b64u(json.dumps(header).encode())
    p = _b64u(json.dumps(claims).encode())
    signing_input = (h + "." + p).encode("ascii")
    if not sign:
        return f"{h}.{p}."
    return f"{h}.{p}.{_b64u(_rs256_sign(signing_input))}"


def good_claims():
    now = int(time.time())
    return {
        "iss": ISSUER, "aud": "spa-client-id", "sub": "auth0|abc",
        "email": "a@b.com", "exp": now + 3600, "iat": now - 5, "nbf": now - 5,
    }


def jwks_with(kid):
    return {"keys": [{"kty": "RSA", "use": "sig", "alg": "RS256",
                      "kid": kid, "n": N_B64U, "e": E_B64U}]}


def load_step_namespace():
    """Extract the `start` step `code` from the playbook and exec it.

    Execs with the flag OFF and a benign token so the top-level flow does no
    network I/O; only the helper functions are needed by the tests.
    """
    import yaml
    with open(PLAYBOOK) as f:
        doc = yaml.safe_load(f)
    step = next(s for s in doc["workflow"] if s.get("step") == "start")
    code = step["tool"]["code"]
    ns = {
        "args": {"auth0_token": "x.y.z", "auth0_domain": ""},
        "input_data": {},
    }
    old = os.environ.get("NOETL_AUTH_VERIFY_SIGNATURE")
    os.environ["NOETL_AUTH_VERIFY_SIGNATURE"] = "off"
    try:
        exec(compile(code, PLAYBOOK, "exec"), ns)
    finally:
        if old is None:
            os.environ.pop("NOETL_AUTH_VERIFY_SIGNATURE", None)
        else:
            os.environ["NOETL_AUTH_VERIFY_SIGNATURE"] = old
    return ns


NS = load_step_namespace()
verify = NS["_verify_with_jwks"]

PASS = 0
FAIL = 0


def ok(name, token, jwks, aud, leeway=0):
    global PASS, FAIL
    r = verify(token, jwks, ISSUER, aud, leeway)
    if r is None:
        PASS += 1
        print("PASS", name)
    else:
        FAIL += 1
        print("FAIL", name, "-> unexpected reject", r)


def rejects(name, token, jwks, aud, outcome, leeway=0):
    global PASS, FAIL
    r = verify(token, jwks, ISSUER, aud, leeway)
    if r is not None and r[0] == outcome:
        PASS += 1
        print("PASS", name, f"({outcome})")
    else:
        FAIL += 1
        print("FAIL", name, f"-> {r} != ({outcome}, ...)")


def check(name, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("PASS", name)
    else:
        FAIL += 1
        print("FAIL", name)


# ── core signature + claims (mirror auth_verify.rs unit tests) ──
ok("valid_token_verifies", make_token(good_claims()), jwks_with(KID), [])
ok("valid_with_matching_audience", make_token(good_claims()), jwks_with(KID), ["spa-client-id"])
ok("audience_not_enforced_when_unconfigured", make_token(good_claims()), jwks_with(KID), [])


def _tamper_sig(tok):
    p = tok.split(".")
    first = p[2][0]
    p[2] = ("B" if first == "A" else "A") + p[2][1:]
    return ".".join(p)


rejects("tampered_signature", _tamper_sig(make_token(good_claims())), jwks_with(KID), [], "bad_signature")


def _tamper_payload(tok):
    p = tok.split(".")
    forged = _b64u(json.dumps({"iss": ISSUER, "sub": "auth0|attacker",
                               "exp": int(time.time()) + 3600}).encode())
    return f"{p[0]}.{forged}.{p[2]}"


rejects("tampered_payload", _tamper_payload(make_token(good_claims())), jwks_with(KID), [], "bad_signature")

_wi = good_claims(); _wi["iss"] = "https://evil.example.com/"
rejects("wrong_issuer", make_token(_wi), jwks_with(KID), [], "bad_claims")

rejects("wrong_audience_when_configured", make_token(good_claims()), jwks_with(KID), ["other-api"], "bad_claims")

_ex = good_claims(); _ex["exp"] = int(time.time()) - 3600
rejects("expired_token", make_token(_ex), jwks_with(KID), [], "bad_claims")

_nb = good_claims(); _nb["nbf"] = int(time.time()) + 3600
rejects("not_yet_valid_nbf", make_token(_nb), jwks_with(KID), [], "bad_claims")

rejects("unknown_kid", make_token(good_claims()), jwks_with("rotated-kid-99"), [], "unknown_kid")

rejects("alg_none_forgery", make_token(good_claims(), alg="none", kid=None, sign=False),
        jwks_with(KID), [], "bad_signature")


# HS256 forgery: attacker signs with HMAC — must be rejected on alg mismatch.
def _hs256_forgery():
    h = _b64u(json.dumps({"alg": "HS256", "typ": "JWT", "kid": KID}).encode())
    p = _b64u(json.dumps(good_claims()).encode())
    import hmac
    sig = hmac.new(b"attacker", f"{h}.{p}".encode(), hashlib.sha256).digest()
    return f"{h}.{p}.{_b64u(sig)}"


rejects("hs256_forgery", _hs256_forgery(), jwks_with(KID), [], "bad_signature")

# leeway: a token expired 30s ago passes with 60s leeway, fails with 0.
_le = good_claims(); _le["exp"] = int(time.time()) - 30
ok("expired_within_leeway", make_token(_le), jwks_with(KID), [], leeway=60)
rejects("expired_outside_leeway", make_token(_le), jwks_with(KID), [], "bad_claims", leeway=0)


# ── flag / mode parsing (mirror verify_mode) ──
def mode_for(v):
    old = os.environ.get("NOETL_AUTH_VERIFY_SIGNATURE")
    if v is None:
        os.environ.pop("NOETL_AUTH_VERIFY_SIGNATURE", None)
    else:
        os.environ["NOETL_AUTH_VERIFY_SIGNATURE"] = v
    try:
        return NS["_verify_mode"]()
    finally:
        if old is None:
            os.environ.pop("NOETL_AUTH_VERIFY_SIGNATURE", None)
        else:
            os.environ["NOETL_AUTH_VERIFY_SIGNATURE"] = old


check("mode_default_off", mode_for(None) == "off")
check("mode_empty_off", mode_for("") == "off")
check("mode_garbage_off", mode_for("yes-please") == "off")
check("mode_shadow", mode_for("shadow") == "shadow")
check("mode_log_shadow", mode_for("log") == "shadow")
check("mode_enforce", mode_for("enforce") == "enforce")
check("mode_true_enforce", mode_for("true") == "enforce")
check("mode_1_enforce", mode_for("1") == "enforce")


# ── end-to-end through _run_signature_verify with a stubbed JWKS fetch ──
def with_stubbed_jwks(jwks, fn):
    orig = NS["_fetch_jwks"]
    NS["_fetch_jwks"] = lambda url: jwks
    try:
        return fn()
    finally:
        NS["_fetch_jwks"] = orig


def run_verify(token, domain=ISSUER_DOMAIN, aud_env=None):
    old_aud = os.environ.get("NOETL_AUTH0_AUDIENCE")
    if aud_env is None:
        os.environ.pop("NOETL_AUTH0_AUDIENCE", None)
    else:
        os.environ["NOETL_AUTH0_AUDIENCE"] = aud_env
    try:
        return NS["_run_signature_verify"](token, domain)
    finally:
        if old_aud is None:
            os.environ.pop("NOETL_AUTH0_AUDIENCE", None)
        else:
            os.environ["NOETL_AUTH0_AUDIENCE"] = old_aud


check("e2e_valid_passes",
      with_stubbed_jwks(jwks_with(KID),
                        lambda: run_verify(make_token(good_claims())) is None))
check("e2e_tampered_rejected",
      with_stubbed_jwks(jwks_with(KID),
                        lambda: (run_verify(_tamper_sig(make_token(good_claims()))) or ("", ""))[0] == "bad_signature"))
check("e2e_aud_env_enforced",
      with_stubbed_jwks(jwks_with(KID),
                        lambda: (run_verify(make_token(good_claims()), aud_env="other-api") or ("", ""))[0] == "bad_claims"))
check("e2e_aud_env_matching_passes",
      with_stubbed_jwks(jwks_with(KID),
                        lambda: run_verify(make_token(good_claims()), aud_env="spa-client-id") is None))
check("e2e_no_domain_when_blank",
      (run_verify(make_token(good_claims()), domain="") or ("", ""))[0] == "no_domain")


# jwks fetch failure → jwks_unavailable (backend problem, not a bad token)
def _boom(url):
    raise RuntimeError("unreachable")


def e2e_jwks_unavailable():
    orig = NS["_fetch_jwks"]
    NS["_fetch_jwks"] = _boom
    try:
        r = NS["_run_signature_verify"](make_token(good_claims()), ISSUER_DOMAIN)
        return r is not None and r[0] == "jwks_unavailable"
    finally:
        NS["_fetch_jwks"] = orig


check("e2e_jwks_unavailable", e2e_jwks_unavailable())


# ── full-step gate wiring: exec the WHOLE `start` body under each mode ──
# Proves the load-bearing constraint: flag off/shadow leaves the historical
# claims-decode result unchanged even for a signature that would fail;
# enforce rejects it.  A fake urlopen returns the test JWKS so the real
# `_fetch_jwks` path runs with no network.
import contextlib
import io
import urllib.request as _url


class _FakeResp:
    status = 200

    def __init__(self, body):
        self._body = body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def run_full_step(flag, token, jwks=None):
    with open(PLAYBOOK) as f:
        import yaml
        step = next(s for s in yaml.safe_load(f)["workflow"] if s.get("step") == "start")
    code = step["tool"]["code"]
    body = json.dumps(jwks if jwks is not None else jwks_with(KID)).encode()
    old_flag = os.environ.get("NOETL_AUTH_VERIFY_SIGNATURE")
    old_urlopen = _url.urlopen
    os.environ["NOETL_AUTH_VERIFY_SIGNATURE"] = flag
    _url.urlopen = lambda url, timeout=5: _FakeResp(body)
    ns = {"args": {"auth0_token": token, "auth0_domain": ISSUER_DOMAIN}, "input_data": {}}
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            exec(compile(code, PLAYBOOK, "exec"), ns)
    finally:
        _url.urlopen = old_urlopen
        if old_flag is None:
            os.environ.pop("NOETL_AUTH_VERIFY_SIGNATURE", None)
        else:
            os.environ["NOETL_AUTH_VERIFY_SIGNATURE"] = old_flag
    return ns["result"]


_valid = make_token(good_claims())
_tampered = _tamper_sig(make_token(good_claims()))

check("full_off_allows_tampered (byte-identical)",
      run_full_step("off", _tampered).get("sub") == "auth0|abc")
check("full_off_allows_valid",
      run_full_step("off", _valid).get("sub") == "auth0|abc")
check("full_shadow_allows_tampered",
      run_full_step("shadow", _tampered).get("sub") == "auth0|abc")
check("full_enforce_rejects_tampered",
      "error" in run_full_step("enforce", _tampered))
check("full_enforce_allows_valid",
      run_full_step("enforce", _valid).get("sub") == "auth0|abc")
# A claims-decode failure (bad issuer) must still short-circuit BEFORE verify
# in every mode — the gate only runs on an otherwise-good claims result.
_badiss = good_claims(); _badiss["iss"] = "https://evil.example.com/"
check("full_enforce_claims_error_preserved",
      "error" in run_full_step("enforce", make_token(_badiss)))


print(f"\n{PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
