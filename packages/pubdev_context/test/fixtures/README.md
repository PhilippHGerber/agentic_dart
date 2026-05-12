# Test Fixtures

Recorded real pub.dev API responses used by unit tests.
One JSON file per endpoint shape.

Committed to the repository — these serve as both deterministic test data
and living documentation of the expected pub.dev response shapes.

**Refreshing fixtures:**
Run the integration tests (`dart test test/integration/`) and use the
`--update-fixtures` flag when one is available, or manually fetch and
replace the relevant JSON file when the pub.dev API shape changes.

Files:
- `search_result.json`       — GET /api/search response
- `package_info.json`        — GET /api/packages/{name} response
- `package_score.json`       — GET /api/packages/{name}/score response
- `package_metrics.json`     — GET /api/packages/{name}/metrics response
- `index_json.json`          — dartdoc /documentation/{name}/latest/index.json
