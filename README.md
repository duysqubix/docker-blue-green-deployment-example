## Blue/Green demo webapp

This repo contains a tiny Node.js web page that highlights which deployment color (blue or green) is currently serving traffic. It uses Traefik as a simple reverse proxy so you can switch between the two stacks and visually confirm the change.

### Prerequisites

- Docker + Docker Compose v2
- The `test-network` docker network (only needs to be created once):

  ```bash
  docker network create test-network
  ```

### Start Traefik (shared services)

```bash
docker compose -f compose.services.yml up -d
```

Traefik will listen on `http://localhost:9001` and forward requests to whichever stack currently has the `traefik.enable=true` label.

### Deploy blue/green

```bash
chmod +x deploy-blue-green.zsh
./deploy-blue-green.zsh
```

- On the first run the script boots the **blue** stack and enables it in Traefik.
- Subsequent runs create/update the idle color, let you validate it, and then flip traffic.
- At any point the script prints the current live color (look for `Current live color: ...`).

### Visual confirmation

1. Visit `http://localhost:9001` and you will see a full-page card with:
   - The active deployment color rendered both as text and as a colored accent.
   - Container metadata (hostname, Traefik status, timestamp) so you can tell which stack you are hitting.
2. Re-run `./deploy-blue-green.zsh` to promote the other color and refresh the page—you should see the UI swap between **blue** and **green** instantly.

### Tearing things down

```bash
# stop the traffic switcher
docker compose -f compose.services.yml down

# remove individual stacks if desired
COMPOSE_PROJECT_NAME=myapp_blue docker compose down
COMPOSE_PROJECT_NAME=myapp_green docker compose down
```
