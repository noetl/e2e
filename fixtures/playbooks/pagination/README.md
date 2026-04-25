# Pagination Test Playbooks

This directory contains comprehensive test suites for HTTP pagination patterns using NoETL's unified retry system.

## 📁 Directory Structure

Each test has a dedicated folder with:
- **Playbook YAML** - Test definition
- **Validation Notebook** - Interactive testing and validation
- **README.md** - Comprehensive documentation

```
pagination/
├── basic/                    # Page-number pagination
│   ├── test_pagination_basic.yaml
│   ├── test_basic_pagination.ipynb
│   └── README.md
├── cursor/                   # Cursor-based pagination
│   ├── test_pagination_cursor.yaml
│   ├── test_cursor_pagination.ipynb
│   └── README.md
├── offset/                   # Offset-based pagination
│   ├── test_pagination_offset.yaml
│   ├── test_offset_pagination.ipynb
│   └── README.md
├── max_iterations/           # Safety limit testing
│   ├── test_pagination_max_iterations.yaml
│   ├── test_max_iterations.ipynb
│   └── README.md
├── retry/                    # Pagination with error retry
│   ├── test_pagination_retry.yaml
│   ├── test_retry_pagination.ipynb
│   └── README.md
└── loop_with_pagination/     # Iterator + pagination combo
    ├── test_loop_with_pagination.yaml
    ├── pagination_loop_test.ipynb
    └── README.md
```

## 🧪 Test Coverage

### 1. [basic/](./basic/) - Page-Number Pagination
**Pattern:** Most common pagination using page numbers
- Uses `page` and `pageSize` parameters
- Continues while `hasMore == true`
- Endpoint: `/api/v1/assessments`
- Validates: 35 items across 4 pages

**Use Case:** Simple REST APIs, user-facing pagination

---

### 2. [cursor/](./cursor/) - Cursor-Based Pagination
**Pattern:** Opaque cursor tokens for stateless navigation
- Uses `cursor` parameter with opaque tokens
- Continues while `next_cursor` is not null/empty
- Endpoint: `/api/v1/events`
- Validates: 35 events across 4 cursor hops

**Use Case:** GraphQL APIs, cloud services, large datasets

---

### 3. [offset/](./offset/) - Offset-Based Pagination
**Pattern:** SQL-style LIMIT/OFFSET pagination
- Uses `offset` and `limit` parameters
- Continues while `has_more == true`
- Endpoint: `/api/v1/users`
- Validates: 35 users across 4 pages

**Use Case:** SQL-backed APIs, direct database pagination

---

### 4. [max_iterations/](./max_iterations/) - Safety Limit Testing
**Pattern:** Controlled pagination with max attempts
- Limits to 2 pages despite more data available
- Demonstrates infinite loop protection
- Endpoint: `/api/v1/assessments`
- Validates: Only 20 items (2 pages × 10), not all 35

**Use Case:** Data sampling, cost control, time constraints

---

### 5. [retry/](./retry/) - Pagination with Error Retry
**Pattern:** Combined error retry and pagination
- Automatic retry on 5xx errors (exponential backoff)
- Continues pagination after successful retry
- Endpoint: `/api/v1/flaky` (intentionally fails on page 2)
- Validates: All 35 items despite transient failures

**Use Case:** Production-grade robust data fetching

---

### 6. [loop_with_pagination/](./loop_with_pagination/) - Iterator + Pagination
**Pattern:** Distributed loops with pagination per iteration
- Server-side iterator over collection of endpoints
- Each iteration fetches paginated data
- Combines event-driven orchestration with retry system
- Validates: 2 iteration jobs, each with pagination

**Use Case:** Multi-endpoint data collection, complex workflows

## 🚀 How to Run Tests

### Option 1: Interactive Notebooks (Recommended)
Each test folder contains a Jupyter notebook for interactive testing:

```bash
cd basic/
jupyter notebook test_basic_pagination.ipynb
```

**Notebooks provide:**
- ✅ Step-by-step execution monitoring
- ✅ Event flow visualization
- ✅ Detailed validation results
- ✅ Auto-detection of environment (localhost/kubernetes)

### Option 2: NoETL API
```bash
# Basic pagination
curl -X POST http://localhost:8082/api/run/playbook \
  -H "Content-Type: application/json" \
  -d '{"path": "tests/pagination/basic"}'

# Cursor pagination
curl -X POST http://localhost:8082/api/run/playbook \
  -H "Content-Type: application/json" \
  -d '{"path": "tests/pagination/cursor"}'
```

### Option 3: NoETL CLI
```bash
noetl run fixtures/playbooks/pagination/basic/test_pagination_basic.yaml
noetl run fixtures/playbooks/pagination/cursor/test_pagination_cursor.yaml
noetl run fixtures/playbooks/pagination/offset/test_pagination_offset.yaml
noetl run fixtures/playbooks/pagination/max_iterations/test_pagination_max_iterations.yaml
noetl run fixtures/playbooks/pagination/retry/test_pagination_retry.yaml
noetl run fixtures/playbooks/pagination/loop_with_pagination/test_loop_with_pagination.yaml
```

## 🎯 Expected Behavior

All pagination tests demonstrate:
1. **Automatic Continuation** - No manual loop code needed
2. **Declarative Syntax** - Clean YAML configuration
3. **Built-in Safety** - max_attempts prevents infinite loops
4. **Result Merging** - Automatic array concatenation
5. **Production Ready** - Error handling and retry support

## 🏗️ Implementation Details

### Unified Retry System

All tests use the `retry.on_success` configuration:

```yaml
retry:
  on_success:
    while: "{{ condition }}"              # Continue while true
    max_attempts: 10                       # Safety limit
    next_call:
      params:                              # Parameters for next page
        page: "{{ calculation }}"
    collect:
      strategy: append                     # How to merge results
      path: data                           # JSON path to array
      into: pages                          # Variable name
```

### Key Features

**Continuation Logic:**
- Server evaluates `while` condition after each successful response
- If `true` and attempts < max_attempts: fetch next page
- If `false` or max reached: stop and return merged result

**Merge Strategies:**
- `append`: Concatenate arrays (most common)
- `replace`: Overwrite with latest (rare)
- Operates on JSON path specified in `path`

**Safety Mechanisms:**
- `max_attempts`: Hard limit on iterations
- Prevents infinite loops from buggy APIs
- Execution logs show "max attempts reached" if triggered

## 📊 Test Server

All tests use the pagination test server:
- **Cluster default**: `http://paginated-api.test-server.svc.cluster.local:5555`
- **Localhost default**: `http://localhost:30555` (NodePort)
- **Override**: set `PAGINATION_API_URL` to point to your target endpoint; playbooks fall back to the localhost NodePort when the variable is not provided.
- **Scheme guard**: if you pass `PAGINATION_API_URL` without `http://` or `https://`, playbooks auto-prepend `http://` to keep requests valid.

**Endpoints:**
- `/api/v1/assessments` - Page-number pagination (35 items)
- `/api/v1/users` - Offset-based pagination (35 items)
- `/api/v1/events` - Cursor-based pagination (35 items)
- `/api/v1/flaky` - Intentionally fails on page 2 (for retry testing)

## 📚 Documentation

Each test folder contains:
- **README.md** - Detailed explanation of pagination pattern
- **Playbook YAML** - Runnable test definition
- **Jupyter Notebook** - Interactive validation and monitoring

For complete architecture details, see [loop_with_pagination/README.md](./loop_with_pagination/README.md).

## ✅ Expected Results

All tests should pass with:
- ✅ Basic pagination: 35 items across 4 pages
- ✅ Cursor pagination: 35 events across 4 cursor hops
- ✅ Offset pagination: 35 users across 4 pages
- ✅ Max iterations: Only 20 items (enforced limit)
- ✅ Retry: All 35 items despite page 2 failure
- ✅ Loop + pagination: 2 iteration jobs, each paginated
