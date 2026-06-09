const std = @import("std");

pub const reload_client_path = "/__sax_live_client.js";

pub const reload_client_script =
    \\// sa_plugin_vite: generated reload client (not user JS).
    \\function showError(message) {
    \\  var el = document.getElementById('__sax_live_error');
    \\  if (!el) {
    \\    el = document.createElement('div');
    \\    el.id = '__sax_live_error';
    \\    el.style.cssText = 'position:fixed;left:16px;right:16px;bottom:16px;z-index:2147483647;background:#210b0b;color:#fff;border:1px solid #e35b5b;padding:12px;font:13px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap;box-shadow:0 8px 24px rgba(0,0,0,.28)';
    \\    document.body.appendChild(el);
    \\  }
    \\  el.textContent = message;
    \\}
    \\function clearError() {
    \\  var el = document.getElementById('__sax_live_error');
    \\  if (el) el.remove();
    \\}
    \\var source = new EventSource('/__sax_live');
    \\source.onmessage = function (event) {
    \\  if (event.data && event.data.indexOf('error:') === 0) {
    \\    showError('SAX rebuild failed. Fix the source and save again.\n' + event.data);
    \\    return;
    \\  }
    \\  clearError();
    \\  location.reload();
    \\};
;

pub const reload_client_tag =
    \\<script type="module" src="/__sax_live_client.js"></script>
;

pub fn injectInto(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, html, reload_client_path) != null) return try allocator.dupe(u8, html);

    if (std.mem.lastIndexOf(u8, html, "</body>")) |idx| {
        return try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}", .{
            html[0..idx],
            reload_client_tag,
            html[idx..],
        });
    }

    return try std.fmt.allocPrint(allocator, "{s}\n{s}\n", .{ html, reload_client_tag });
}

test "injects reload client before body close" {
    const html = "<html><body><main></main></body></html>";
    const injected = try injectInto(std.testing.allocator, html);
    defer std.testing.allocator.free(injected);

    try std.testing.expect(std.mem.indexOf(u8, injected, reload_client_path) != null);
    const script_idx = std.mem.indexOf(u8, injected, "<script").?;
    const body_idx = std.mem.indexOf(u8, injected, "</body>").?;
    try std.testing.expect(script_idx < body_idx);
}

test "injection is idempotent" {
    const html = "<html><body><script type=\"module\" src=\"/__sax_live_client.js\"></script></body></html>";
    const injected = try injectInto(std.testing.allocator, html);
    defer std.testing.allocator.free(injected);
    try std.testing.expectEqualStrings(html, injected);
}
