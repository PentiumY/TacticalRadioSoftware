import type { PlayerRadioState } from "@milsim/protocol";

export type ActivePlayerSession = {
  placeId: number;
  jobId: string;
};

export class PlayerStateStore {
  private readonly players = new Map<string, PlayerRadioState>();

  upsert(state: PlayerRadioState): void {
    this.players.set(this.key(state.placeId, state.jobId, state.robloxUserId), state);
  }

  listForServer(placeId: number, jobId: string): PlayerRadioState[] {
    return [...this.players.values()].filter(
      (p) => p.placeId === placeId && p.jobId === jobId
    );
  }

  listSessionsForUsername(username: string, maxAgeMs = 5000): ActivePlayerSession[] {
    const target = username.trim().toLowerCase();
    if (!target) return [];

    const now = Date.now();
    const unique = new Map<string, ActivePlayerSession>();
    for (const player of this.players.values()) {
      if (now - player.updatedAtMs > maxAgeMs) continue;
      if ((player.username ?? "").toLowerCase() !== target) continue;
      if (!Number.isFinite(player.placeId) || !player.jobId) continue;

      const session = { placeId: player.placeId, jobId: player.jobId };
      unique.set(JSON.stringify([session.placeId, session.jobId]), session);
    }
    return [...unique.values()].sort(
      (a, b) => a.placeId - b.placeId || a.jobId.localeCompare(b.jobId)
    );
  }

  pruneOlderThan(maxAgeMs: number): number {
    const now = Date.now();
    let removed = 0;
    for (const [key, state] of this.players) {
      if (now - state.updatedAtMs > maxAgeMs) {
        this.players.delete(key);
        removed++;
      }
    }
    return removed;
  }

  private key(placeId: number, jobId: string, robloxUserId: number): string {
    return `${placeId}:${jobId}:${robloxUserId}`;
  }
}
