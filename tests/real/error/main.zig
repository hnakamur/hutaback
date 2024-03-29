const std = @import("std");

const bad_req_content_len = @import("bad_req_content_len.zig");
const bad_req_http_version = @import("bad_req_http_version.zig");
const bad_resp_content_len = @import("bad_resp_content_len.zig");
const bad_resp_http_version = @import("bad_resp_http_version.zig");

const client_recv_timeout = @import("client_recv_timeout.zig");
const client_send_timeout = @import("client_send_timeout.zig");
const connection_refused = @import("connection_refused.zig");
const connection_timedout = @import("connection_timedout.zig");

const bad_resp_status = @import("bad_resp_status.zig");
const drop_server_recv = @import("drop_server_recv.zig");
const http09_unsupported = @import("http09_unsupported.zig");
const http2_unsupported = @import("http2_unsupported.zig");
const req_content_eof = @import("req_content_eof.zig");
const req_content_timeout = @import("req_content_timeout.zig");
const req_hdr_eof = @import("req_hdr_eof.zig");
const resp_content_eof = @import("resp_content_eof.zig");
const resp_content_timeout = @import("resp_content_timeout.zig");
const resp_hdr_eof = @import("resp_hdr_eof.zig");

const server_alloc_fail_case1 = @import("server_alloc_fail_case1.zig");
const server_alloc_fail_case2 = @import("server_alloc_fail_case2.zig");

const too_long_req_hdr = @import("too_long_req_hdr.zig");
const too_long_req_method = @import("too_long_req_method.zig");
const too_long_req_uri = @import("too_long_req_uri.zig");
const too_long_resp_hdr = @import("too_long_resp_hdr.zig");

const proxy_connect_origin_err = @import("proxy_connect_origin_err.zig");
const proxy_recv_req_content_err = @import("proxy_recv_req_content_err.zig");
const proxy_recv_req_hdr_err = @import("proxy_recv_req_hdr_err.zig");
const proxy_recv_resp_hdr_err = @import("proxy_recv_resp_hdr_err.zig");
const proxy_recv_resp_content_err = @import("proxy_recv_resp_content_err.zig");

comptime {
    std.testing.refAllDecls(@This());
}
