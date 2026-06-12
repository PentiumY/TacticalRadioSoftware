import Fastify from "fastify";
import websocket from "@fastify/websocket";
import { PlayerStateStore } from "./playerStateStore.js";
import { TxLockStore } from "./txLockStore.js";

const app = Fastify({ logger: true });

const playerStates = new PlayerStateStore();
const txLocks = new TxLockStore();

await app.register(websocket);

type RadioEar = "left" | "right" | "both";

type PlayerRadioState = {
  id: number | string;
  channel: string;
  listening: boolean;
  transmitting: boolean;
  ear: RadioEar;
  volume: number;
  minDistance: number;
  maxDistance: number;
};

type StoredPlayerWithRadios = {
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
  radios?: PlayerRadioState[];
};

function numberOrZero(value: string | undefined): number {
  if (!value) {
    return 0;
  }

  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function defaultRadiosForPlayer(player: StoredPlayerWithRadios): PlayerRadioState[] {
  return [
    {
      id: player.radioId ?? "primary",
      channel: player.frequency,
      listening: true,
      transmitting: player.isPtt,
      ear: "both",
      volume: 1.0,
      minDistance: 0,
      maxDistance: 3000
    }
  ];
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
      radios?: PlayerRadioState[];
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

app.get<{
  Querystring: {
    placeId: string;
    jobId: string;
  };
}>("/v1/plugin/stereo", async (request) => {
  const placeId = Number(request.query.placeId);
  const jobId = request.query.jobId;

  const players = playerStates.listForServer(placeId, jobId) as StoredPlayerWithRadios[];

  return {
    nowMs: Date.now(),
    placeId,
    jobId,
    players: players.map((player) => {
      const radios = player.radios ?? defaultRadiosForPlayer(player);

      return {
        robloxUserId: player.robloxUserId,
        username: player.username,
        displayName: player.displayName,
        team: player.team,
        squad: player.squad,
        radios: radios.map((radio) => ({
          id: radio.id,
          channel: radio.channel,
          listening: radio.listening,
          transmitting: radio.transmitting,
          ear: radio.ear,
          stereoEnabled: radio.ear === "left" || radio.ear === "right",
          volume: radio.volume,
          minDistance: radio.minDistance,
          maxDistance: radio.maxDistance
        }))
      };
    })
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