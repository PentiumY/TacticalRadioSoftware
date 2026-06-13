import Fastify from "fastify";
import websocket from "@fastify/websocket";
import { PlayerStateStore } from "./playerStateStore.js";
import { TxLockStore } from "./txLockStore.js";

const app = Fastify({ logger: true });

const playerStates = new PlayerStateStore();
const txLocks = new TxLockStore();

await app.register(websocket);

type RadioEar = "left" | "right" | "both";

type Vec3 = {
  x: number;
  y: number;
  z: number;
};

type PlayerRadioState = {
  id: number | string;
  radioId?: string;
  channel: string;
  listening: boolean;
  transmitting: boolean;
  ear: RadioEar;
  stereoEnabled?: boolean;
  volume: number;
  minDistance: number;
  maxDistance: number;
};

type SpeechHearingOverride = {
  remoteRobloxUserId: number;
  obstruction: number;
  volumeMultiplier: number;
  maxDistanceMultiplier: number;
  muffled: boolean;
};

type StoredPlayerWithRadios = {
  placeId?: number;
  jobId?: string;
  updatedAtMs?: number;

  robloxUserId: number;
  username?: string;
  displayName?: string;

  position: Vec3;
  lookVector: Vec3;

  speechMode?: string;
  speechVolume: number;
  speechMinDistance: number;
  speechMaxDistance: number;
  hearing: SpeechHearingOverride[];

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

function finiteNumber(value: unknown, fallback: number): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function clampNumber(value: unknown, fallback: number, min: number, max: number): number {
  const parsed = finiteNumber(value, fallback);
  return Math.max(min, Math.min(max, parsed));
}

function normalizeEar(value: unknown): RadioEar {
  const ear = String(value ?? "both").toLowerCase();

  if (ear === "left" || ear === "right" || ear === "both") {
    return ear;
  }

  return "both";
}

function normalizeVec3(value: unknown, fallback: Vec3): Vec3 {
  if (!value || typeof value !== "object") {
    return fallback;
  }

  const raw = value as Partial<Vec3>;

  return {
    x: finiteNumber(raw.x, fallback.x),
    y: finiteNumber(raw.y, fallback.y),
    z: finiteNumber(raw.z, fallback.z)
  };
}

function normalizeRadio(raw: Partial<PlayerRadioState> | undefined): PlayerRadioState {
  const minDistance = clampNumber(raw?.minDistance, 0, 0, 100000);
  const maxDistance = clampNumber(raw?.maxDistance, 3000, minDistance + 1, 100000);

  return {
    id: raw?.id ?? raw?.radioId ?? "primary",
    radioId: raw?.radioId,
    channel: String(raw?.channel ?? ""),
    listening: raw?.listening === true,
    transmitting: raw?.transmitting === true,
    ear: normalizeEar(raw?.ear),
    stereoEnabled: raw?.stereoEnabled === true,
    volume: clampNumber(raw?.volume, 1.0, 0, 2),
    minDistance,
    maxDistance
  };
}

function normalizeHearingOverride(raw: Partial<SpeechHearingOverride>): SpeechHearingOverride | null {
  const remoteRobloxUserId = Math.trunc(finiteNumber(raw.remoteRobloxUserId, 0));

  if (remoteRobloxUserId <= 0) {
    return null;
  }

  return {
    remoteRobloxUserId,
    obstruction: clampNumber(raw.obstruction, 0, 0, 1),
    volumeMultiplier: clampNumber(raw.volumeMultiplier, 1, 0, 1),
    maxDistanceMultiplier: clampNumber(raw.maxDistanceMultiplier, 1, 0, 1),
    muffled: raw.muffled === true
  };
}

function defaultRadiosForPlayer(player: StoredPlayerWithRadios): PlayerRadioState[] {
  return [
    {
      id: player.radioId ?? "primary",
      radioId: player.radioId,
      channel: player.frequency,
      listening: true,
      transmitting: player.isPtt,
      ear: "both",
      stereoEnabled: false,
      volume: 1.0,
      minDistance: 0,
      maxDistance: 3000
    }
  ];
}

function normalizePlayer(
  player: Partial<StoredPlayerWithRadios>,
  placeId: number,
  jobId: string,
  updatedAtMs: number
): StoredPlayerWithRadios {
  const speechMinDistance = clampNumber(player.speechMinDistance, 8, 0, 10000);
  const speechMaxDistance = clampNumber(
    player.speechMaxDistance,
    90,
    speechMinDistance + 1,
    10000
  );

  const radios = Array.isArray(player.radios)
    ? player.radios.map((radio) => normalizeRadio(radio)).filter((radio) => radio.channel !== "")
    : undefined;

  const hearing = Array.isArray(player.hearing)
    ? player.hearing
        .map((entry) => normalizeHearingOverride(entry))
        .filter((entry): entry is SpeechHearingOverride => entry !== null)
    : [];

  return {
    placeId,
    jobId,
    updatedAtMs,

    robloxUserId: Math.trunc(finiteNumber(player.robloxUserId, 0)),
    username: player.username,
    displayName: player.displayName,

    position: normalizeVec3(player.position, { x: 0, y: 0, z: 0 }),
    lookVector: normalizeVec3(player.lookVector, { x: 0, y: 0, z: -1 }),

    speechMode: String(player.speechMode ?? "normal"),
    speechVolume: clampNumber(player.speechVolume, 1.0, 0, 2),
    speechMinDistance,
    speechMaxDistance,
    hearing,

    frequency: String(player.frequency ?? ""),
    isPtt: player.isPtt === true,
    team: player.team,
    squad: player.squad,
    radioId: player.radioId,
    radios
  };
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
    players: Array<Partial<StoredPlayerWithRadios>>;
  };
}>("/v1/roblox/state", async (request) => {
  const nowMs = Date.now();
  const placeId = finiteNumber(request.body.placeId, 0);
  const jobId = String(request.body.jobId ?? "");

  for (const player of request.body.players ?? []) {
    const normalized = normalizePlayer(player, placeId, jobId, nowMs);

    if (normalized.robloxUserId > 0) {
      playerStates.upsert(normalized as any);
    }
  }

  return {
    ok: true,
    accepted: request.body.players?.length ?? 0,
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

        speechMode: player.speechMode,
        speechVolume: player.speechVolume,
        speechMinDistance: player.speechMinDistance,
        speechMaxDistance: player.speechMaxDistance,
        hearing: player.hearing,

        radios: radios.map((radio) => ({
          id: radio.id,
          radioId: radio.radioId,
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