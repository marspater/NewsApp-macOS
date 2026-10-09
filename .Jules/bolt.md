## Performance Optimizations

* When interacting with SQLite via the C API in Swift loops, avoid calling `sqlite3_prepare_v2` on every iteration to prevent an N+1 performance bottleneck. Prepare the statement once outside the loop, and use `sqlite3_reset` and `sqlite3_bind_*` inside the loop.
