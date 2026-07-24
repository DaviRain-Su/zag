# zig-curl (vendored for Zag)

Snapshot of [jiacai2050/zig-curl](https://github.com/jiacai2050/zig-curl) **v0.5.0** (MIT).

Used only when Zag is built with `-Dhttp_backend=curl` (see D-005). Default remains `std.http.Client`.

Spike links **system** libcurl (`link_vendor=false`) to keep compile light; vendor mbedtls/curl is available via zig-curl's own `-Dlink_vendor=true` if we need hermetic CI later.
