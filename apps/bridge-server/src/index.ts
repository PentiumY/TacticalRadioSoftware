import Fastify from "fastify";
import websocket from "@fastify/websocket";
import { PlayerStateStore } from "./playerStateStore.js";
import { TxLockStore } from "./txLockStore.js";

const app = Fastify({ logger: true });

const playerStates = new PlayerStateStore();
const txLocks = new TxLockStore();

await app.register(websocket);

function numberOrZero(value: string | undefined): number {
  if (!value) {
    return 0;
  }

  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

app.get("/health", async () => {
  return {
    ok: true,
    nowMs: Date.now()
  };
});

app.post<{
  Body: {
    placeId: number;
    jobId: string;
    players: Array<{
      robloxUserId: number;
      username?: string;
      displayName?: string;
      position: { x: number; y: number; z: number };
      lookVector: { x: number; y: number; z: number };
      frequency: string;
      isPtt: boolean;
      team?: string;
      squad?: string;
      radioId?: string;
    }>;
  };
}>("/v1/roblox/state", async (request) => {
  const nowMs = Date.now();

  for (const player of request.body.players) {
    playerStates.upsert({
      ...player,
      placeId: request.body.placeId,
      jobId: request.body.jobId,
      updatedAtMs: nowMs
    });
  }

  return {
    ok: true,
    accepted: request.body.players.length,
    nowMs
  };
});

app.post<{
  Body: {
    placeId: number;
    jobId: string;
    frequency: string;
    robloxUserId: number;
  };
}>("/v1/tx/start", async (request) => {
  const result = txLocks.requestTx({
    ...request.body,
    ttlMs: 1200
  });

  return result;
});

app.post<{
  Body: {
    placeId: number;
    jobId: string;
    frequency: string;
    robloxUserId: number;
    token: string;
  };
}>("/v1/tx/heartbeat", async (request) => {
  const ok = txLocks.heartbeat({
    ...request.body,
    ttlMs: 1200
  });

  return { ok };
});

app.post<{
  Body: {
    placeId: number;
    jobId: string;
    frequency: string;
    robloxUserId: number;
    token: string;
  };
}>("/v1/tx/stop", async (request) => {
  const ok = txLocks.release(request.body);

  return { ok };
});

app.get<{
  Querystring: {
    placeId: string;
    jobId: string;
    localRobloxUserId?: string;
    localRobloxUsername?: string;
  };
}>("/v1/plugin/snapshot", async (request) => {
  const placeId = Number(request.query.placeId);
  const jobId = request.query.jobId;

  const localRobloxUserId = numberOrZero(request.query.localRobloxUserId);
  const localRobloxUsername = request.query.localRobloxUsername ?? "";

  return {
    nowMs: Date.now(),
    localRobloxUserId,
    localRobloxUsername,
    players: playerStates.listForServer(placeId, jobId),
    txLocks: txLocks.listForServer(placeId, jobId)
  };
});

setInterval(() => {
  playerStates.pruneOlderThan(5000);
  txLocks.pruneExpired();
}, 1000).unref();

const port = Number(process.env.PORT ?? 3000);

await app.listen({
  port,
  host: "0.0.0.0"
});