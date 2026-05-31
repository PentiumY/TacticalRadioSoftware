import type { PlayerRadioState } from "@milsim/protocol";

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