export default function Page() {
  return (
    <main style={{ fontFamily: "system-ui", padding: "2rem", lineHeight: 1.6 }}>
      <h1>Universal I/O Copilot API</h1>
      <p>
        This host serves the iOS app only. See <code>POST /api/analyze</code> and{" "}
        <code>GET /api/packs</code>.
      </p>
    </main>
  );
}
