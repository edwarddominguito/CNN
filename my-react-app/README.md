# Rice classifier web client

Use Node.js 24 and `npm ci` to install the locked dependencies.

For local development, start the backend on port 8000, then run `npm run dev`.
Vite proxies the API routes to `http://127.0.0.1:8000`. You can override that
target with `VITE_API_URL=http://YOUR_BACKEND:8000` in `.env.local`.

For the repository's Railway Docker deployment, leave `VITE_API_URL` empty.
The backend serves `dist` from the same HTTPS origin as `/predict`.
For separate hosting, set `VITE_API_URL=https://your-backend.up.railway.app`
**before building** and allow the frontend origin in backend `CORS_ORIGINS`.
Vite embeds this public URL in the bundle; it is not a secret or runtime setting.

Run `npm run lint`, `npm test`, and `npm run build` before deploying.
Upload requests have a two-minute deadline and accept JPG, PNG, and WebP files
up to 15 MB. The server validates image contents and model readiness.
