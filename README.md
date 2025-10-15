# tsnsrv - a reverse proxy on your tailnet

> **🔀 FORK NOTICE**
>
> This is a feature-enhanced fork of tsnsrv with significant additions:
> - **Multi-service mode**: Run multiple services in a single process (CLI flags or YAML config)
> - **Forward authentication**: Integration with Authelia, Authentik, and other auth providers
> - **Enhanced NixOS module**: Multi-service support, OCI sidecars, ACME integration
> - **Tailscale user bypass**: Skip external auth for Tailscale-authenticated users
>
> These features are not available in the original upstream version.

---

This package includes a little go program that sets up a reverse proxy
listening on your tailnet (optionally with a funnel), forwarding
requests to a service reachable from the machine running this
program. This is directly and extremely inspired by the [amazing talk
by Xe Iaso](https://tailscale.com/blog/tsup-tsnet) about the wonderful
things one can do with
[`tsnet`](https://pkg.go.dev/tailscale.com/tsnet).

## Why use this?

First, you'll want to watch the talk linked above. But if you still
have that question: Say you run a service that you haven't written
yourself (we can't all be as wildly productive as Xe), but you'd still
like to benefit from tailscale's access control, encrypted
communication and automatic HTTPS cert provisioning? Then you can just
run that service, have it listen on localhost or a unix domain socket,
then run `tsnsrv` and have that expose the service on your tailnet
(or, as I mentioned, on the funnel).

### Is this probably full of horrible bugs that will make you less secure or more unhappy?

Almost certainly:

* I have not thought much about request forgery.

* You're by definition forwarding requests of one degree of
  trustedness to a thing of another degree of trustedness.

* This tool uses go's `httputil.ReverseProxy`, which seems notorious
  for having bugs in its mildly overly-naive URL path rewriting
  (especially resulting in an extraneous `/` getting appended to the
  destination URL path).

## So how do you use this?

First, you have to have a service you want to proxy to, reachable from
the machine that runs tsnsrv. I'll assume it serves plaintext HTTP on
`127.0.0.1:8000`, but it could be on any address, reachable over ipv4
or v6. Assume the service is called `happy-computer`.

Then, you have options:

* Expose the service on your tailnet (and only your tailnet):
  `tsnsrv -name happy-computer http://127.0.0.1:8000`

* Expose the entire service on your tailnet and on the internet:
  `tsnsrv -name happy-computer -funnel http://127.0.0.1:8000`

### Access control to public funnel endpoints

Now, running a whole service on the internet doesn't feel great
(especially if the authentication/authorization story depended on it
being reachable only on your tailnet); you might want to expose only a
webhook endpoint from a separate tsnsrv invocation, that allows access
only to one or a few subpaths. Assuming you want to run a matrix
server:

```sh
tsnsrv -name happy-computer-webhook -funnel -stripPrefix=false -prefix /_matrix -prefix /_synapse/client http://127.0.0.1:8000
```

Each `-prefix` flag adds a path to the list of URLs that external
clients can see (Anything outside that list returns a 404).

The `-stripPrefix` flag tells tsnsrv to leave the prefix intact: By default, it strips off the matched portion, so that you can run it with:
`tsnsrv -name hydra-webhook -funnel -prefix /api/push-github http://127.0.0.1:3001/api/push-github`
which would be identical to
`tsnsrv -name hydra-webhook -funnel -prefix /api/push-github -stripPrefix=false http://127.0.0.1:3001`

### Authorization with external services

`tsnsrv` supports forward authentication integration with external authorization services like [Authelia](https://www.authelia.com/), [Authentik](https://goauthentik.io/), or custom auth services. This works similarly to Caddy's `forward_auth` directive.

To enable authorization:

```sh
tsnsrv -name protected-app -authURL http://authelia:9091 -authCopyHeader "Remote-User: " -authCopyHeader "Remote-Groups: " http://127.0.0.1:8000
```

#### Configuration flags:

* `-authURL` - URL of the authorization service (e.g., `http://authelia:9091`)
* `-authPath` - Authorization endpoint path (default: `/api/authz/forward-auth`)
* `-authTimeout` - Timeout for authorization requests (default: `5s`)
* `-authCopyHeader` - Headers to copy from auth response to upstream request
* `-authInsecureHTTPS` - Disable TLS certificate validation for auth service
* `-authBypassForTailnet` - Bypass forward auth for requests from authenticated Tailscale users

#### How it works:

1. For each incoming request, `tsnsrv` makes a GET request to the auth service
2. The auth service receives headers like `X-Original-Method`, `X-Original-URL`, `X-Forwarded-Host`, etc.
3. If the auth service returns a 2xx status code, the request proceeds and configured headers are copied
4. If the auth service returns any other status code, that response is returned to the client (typically a redirect to login)

#### Bypassing auth for Tailscale users:

When `-authBypassForTailnet` is enabled, requests from authenticated Tailscale users will skip the external auth service entirely. This is useful when you want to:
- Use external auth for public/funnel access
- Allow direct access for users already authenticated via Tailscale
- Reduce latency for internal users by skipping the auth round-trip

Example:
```sh
# Public users go through Authelia, Tailscale users bypass it
tsnsrv -name my-app -funnel \
  -authURL http://authelia:9091 \
  -authBypassForTailnet \
  http://localhost:8080
```

#### Example with Authelia:

Command line:
```sh
# Run tsnsrv with Authelia forward auth
tsnsrv -name my-app \
  -authURL https://auth.example.com \
  -authPath /api/authz/forward-auth \
  -authCopyHeader "Remote-User: " \
  -authCopyHeader "Remote-Groups: " \
  -authCopyHeader "Remote-Name: " \
  -authCopyHeader "Remote-Email: " \
  http://localhost:8080
```

NixOS configuration:
```nix
services.tsnsrv = {
  enable = true;
  defaults = {
    authKeyPath = config.age.secrets.tailscale-authkey.path;
  };
  services = {
    my-app = {
      urlParts = {
        protocol = "http";
        host = "localhost";
        port = 8080;
      };
      funnel = true;  # Optional: expose on public internet
      authURL = "http://authelia:9091";
      authPath = "/api/authz/forward-auth";
      authTimeout = "10s";
      authCopyHeaders = {
        "Remote-User" = "";
        "Remote-Groups" = "";
        "Remote-Email" = "";
      };
      # Optional: bypass auth for Tailscale-authenticated users
      authBypassForTailnet = true;
    };
  };
};
```

This configuration will:
- Forward all requests to Authelia for authentication
- Copy user identity headers (Remote-User, Remote-Groups, Remote-Email) to the upstream service
- Allow Tailscale users to bypass Authelia authentication (when `authBypassForTailnet = true`)
- Expose the service on the public internet via Tailscale Funnel (when `funnel = true`)

### Passing requestor information to upstream services

Unless given the `-suppressWhois` flag, `tsnsrv` will look up
information about the requesting user and their node, and attach the
following headers:

* `X-Tailscale-User` - numeric ID of the user that made the request
* `X-Tailscale-User-LoginName` - login name of the user that made the request: e.g., `foo@example.com`
* `X-Tailscale-User-LoginName-Localpart` - login name of the user that made the request, but only the local part (e.g., `foo`)
* `X-Tailscale-User-LoginName-Domain` - login name of the user that made the request, but only the domain name (e.g., `example.com`)
* `X-Tailscale-User-DisplayName` - display name of the user
* `X-Tailscale-User-ProfilePicURL` - their profile picture, if one exists
* `X-Tailscale-Caps` - user capabilities
* `X-Tailscale-Node` - numeric ID of the node originating the request
* `X-Tailscale-Node-Name` - name of the node originating the request
* `X-Tailscale-Node-Caps` - node device capabilities
* `X-Tailscale-Node-Tags` - ACL tags on the origin node

### Using OAuth clients instead of tailscale API keys

If you intend to deploy several tsnsrv instances to a server over a
long time (and intend to bring up more services as the months go on),
you might worry that the maximum tailscale Auth key lifetime might be
a problem. It is, but it is less so than you might think:

* Each tsnsrv service stores its "per-host" key in the state
  directory, and doesn't expire, but:
* the key used to create *new* tsnsrv instances has an expiry date -
  so after at most 3 months, you will have to rotate the key (and
  deploys fail, etc).

There is a remedy to the issue of the expiring "new service
registration" issue: [Tailscale OAuth
clients](https://tailscale.com/kb/1215/oauth-clients). These only work
with the cloud tailscale (not with headscale, AIUI), and they have
some requirements:

* You need an OAuth client minted with `auth_key` permissions,
* the client needs to specify *exactly* the tags you want to run the service under, and
* you need to specify exactly those tags on tsnsrv's commandline with the `-tag` flag.

Once you have a oauth client (and a command line) with these
requirements, all you need to do is to use the client _secret_ (the
client ID is irrelevant for us) as the tailscale auth key and tsnsrv
will do the rest.

### Running multiple services in a single process

When running many tsnsrv services on the same machine, you can reduce resource overhead by running them in a single process. Instead of running separate `tsnsrv` invocations for each service, a single tsnsrv process can manage multiple services.

#### Command line usage

Create a YAML configuration file (e.g., `config.yaml`):

```yaml
services:
  - name: web-app
    upstream: http://localhost:8080
    funnel: true
    authURL: http://authelia:9091
    authCopyHeaders:
      Remote-User: ""
      Remote-Groups: ""

  - name: internal-api
    upstream: http://localhost:8081
    funnel: false
    suppressWhois: false

  - name: public-docs
    upstream: http://localhost:8082
    funnel: true
    prefixes:
      - funnel:/docs
      - funnel:/api
```

Then run tsnsrv with the `-config` flag:

```sh
tsnsrv -config config.yaml
```

> **⚠️ IMPORTANT**: When using `-config` mode, command-line flags (except `-config` itself) are **completely ignored**. All configuration must be in the YAML file, including critical settings like `stateDir` and `authkeyPath`. If you need to override these per-service, add them to each service definition in the config file:
>
> ```yaml
> services:
>   - name: my-service
>     upstream: http://localhost:8080
>     stateDir: /var/lib/tsnsrv/my-service
>     authkeyPath: /etc/tsnsrv/authkey.secret
> ```

See `config.example.yaml` for a complete example with all available options.

#### Using CLI flags (no config file required)

As an alternative to config files, you can define multiple services directly via CLI flags using the `-service` flag (repeatable):

```sh
tsnsrv \
  -service "name=web-app,upstream=http://localhost:8080,funnel=true" \
  -service "name=internal-api,upstream=http://localhost:8081,funnel=false"
```

**Available configuration keys** (comma-separated `key=value` pairs):
- **Required**: `name`, `upstream`
- **Tailscale**: `ephemeral`, `tag`, `stateDir`, `authkeyPath`
- **Network**: `funnel`, `funnelOnly`, `listenAddr`, `plaintext`
- **Proxy**: `recommendedProxyHeaders`, `prefix`, `stripPrefix`, `upstreamHeader`
- **Auth**: `authURL`, `authPath`, `authTimeout`, `authCopyHeader`, `authInsecureHTTPS`, `authBypassForTailnet`
- **Security**: `insecureHTTPS`, `upstreamAllowInsecureCiphers`
- **Monitoring**: `prometheusAddr`
- And more (see CLAUDE.md for complete list)

**Boolean values**: `true`/`false`, `yes`/`no`, `1`/`0` (case-insensitive)

**Duration values**: Use Go duration format like `1s`, `5m`, `1h30m`

**Multiple values** (tags, prefixes, headers): Repeat the key:
```sh
tsnsrv -service "name=web,upstream=http://localhost:8080,tag=tag:web,tag=tag:prod,prefix=/api,prefix=/public"
```

**Complete example with auth:**
```sh
tsnsrv \
  -service "name=web-app,upstream=http://localhost:8080,funnel=true,authURL=http://authelia:9091,authCopyHeader=Remote-User:,authCopyHeader=Remote-Groups:,authBypassForTailnet=true" \
  -service "name=internal-api,upstream=http://localhost:8081,funnel=false,tag=tag:api"
```

**Note**: The three modes (single-service CLI, config file, and multi-service CLI) are mutually exclusive - you cannot mix them.

#### NixOS configuration

In NixOS, the module always runs all configured services in a single systemd unit (`tsnsrv-all.service`):

```nix
services.tsnsrv = {
  enable = true;

  defaults = {
    authKeyPath = config.age.secrets.tailscale-authkey.path;
    urlParts.host = "localhost";
  };

  services = {
    web-app = {
      urlParts.port = 8080;
      funnel = true;
      authURL = "http://authelia:9091";
      authCopyHeaders = {
        "Remote-User" = "";
        "Remote-Groups" = "";
      };
    };

    internal-api = {
      urlParts.port = 8081;
      funnel = false;
    };

    public-docs = {
      urlParts.port = 8082;
      funnel = true;
      prefixes = [
        "funnel:/docs"
        "funnel:/api"
      ];
    };
  };
};
```

**Benefits:**
- Reduced memory footprint (single Go process, single tsnet instance)
- Lower CPU overhead from fewer processes
- Shared Prometheus metrics endpoint for all services
- Simpler systemd service management
