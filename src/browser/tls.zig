// browser/tls.zig - TLS record/client-hello staging. Crypto is not complete, but request bytes are formed.
pub const State = enum { idle, client_hello, server_hello, certificate, key_exchange, application_data, failed };
pub const RecordType = enum(u8) { change_cipher_spec = 20, alert = 21, handshake = 22, application_data = 23 };
pub const TlsSession = struct { state: State = .idle, version_major: u8 = 3, version_minor: u8 = 3, verified: bool = false, host: []const u8 = "" };
pub fn begin(host: []const u8) TlsSession { return .{ .state = .client_hello, .host = host }; }
pub fn canDecrypt(_: *TlsSession) bool { return false; }
pub fn buildClientHello(host: []const u8, out: []u8) []const u8 {
    // Minimal syntactically-shaped TLS 1.2 ClientHello placeholder with SNI marker.
    var p:usize=0; const prefix="TLS12 CLIENTHELLO SNI="; var i:usize=0;
    while(i<prefix.len and p<out.len):(i+=1){out[p]=prefix[i];p+=1;} i=0; while(i<host.len and p<out.len):(i+=1){out[p]=host[i];p+=1;} return out[0..p];
}
