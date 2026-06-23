## ADDED Requirements

### Requirement: Browser-trusted certificate for public services
Public services exposed under `*.watchtoken.org` MUST be served with a
browser-trusted TLS certificate issued by Let's Encrypt.

#### Scenario: Visitor opens a public app over HTTPS
- **WHEN** a visitor requests `https://cv.watchtoken.org` (or forgejo/vault)
- **THEN** Traefik presents a valid Let's Encrypt certificate for
  `*.watchtoken.org` and the connection is trusted by browsers without warnings.

### Requirement: Automated certificate issuance and renewal
Certificates MUST be issued and renewed automatically, without manual
intervention, using DNS-01 challenges solved via the Cloudflare API.

#### Scenario: Certificate nears expiry
- **WHEN** the wildcard certificate is within 30 days of expiry
- **THEN** cert-manager re-solves the DNS-01 challenge and refreshes the Secret,
  and Traefik begins serving the renewed certificate with no manual action.

### Requirement: HTTP requests are redirected to HTTPS
Public HTTP requests MUST be permanently redirected to HTTPS.

#### Scenario: Plain-HTTP request to a public host
- **WHEN** a client requests `http://cv.watchtoken.org`
- **THEN** Traefik returns a permanent (301) redirect to the `https://` equivalent.

### Requirement: Internal LAN access stays HTTP
Internal `*.local` hosts accessed over the LAN MUST continue to be served over
plain HTTP unchanged.

#### Scenario: LAN client uses an internal host
- **WHEN** a LAN client requests `http://cv.local`
- **THEN** the request is served over HTTP (no TLS, no redirect), as before.

### Requirement: Cloudflare tunnel uses Full Strict
The Cloudflare Tunnel origin MUST connect to Traefik over HTTPS (port 443) so
that traffic is encrypted end-to-end from Cloudflare's edge to Traefik.

#### Scenario: After HTTPS is enabled on Traefik
- **WHEN** the public HTTP→HTTPS redirect is active
- **THEN** the Cloudflare Tunnel origin is configured as `https://traefik:443`
  (Full strict), avoiding a redirect loop and preserving end-to-end encryption.
