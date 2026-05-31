import crypto from "node:crypto";
import type { TxLock } from "@milsim/protocol";

export type TxGrantResult =
  | { granted: true; lock: TxLock }
  | { granted: false; currentOwnerRobloxUserId: number; expiresAtMs: number };

export class TxLockStore {
  private readonly locks = new Map<string, TxLock>();

  requestTx(input: {
    placeId: number;
    jobId: string;
    frequency: string;
    robloxUserId: number;
    ttlMs: number;
  }): TxGrantResult {
    const now = Date.now();
    const key = this.key(input.placeId, input.jobId, input.frequency);
    const existing = this.locks.get(key);

    if (existing && existing.expiresAtMs > now) {
      if (existing.ownerRobloxUserId !== input.robloxUserId) {
        return {
          granted: false,
          currentOwnerRobloxUserId: existing.ownerRobloxUserId,
          expiresAtMs: existing.expiresAtMs
        };
      }

      existing.expiresAtMs = now + input.ttlMs;
      return { granted: true, lock: existing };
    }

    const lock: TxLock = {
      placeId: input.placeId,
      jobId: input.jobId,
      frequency: input.frequency,
      ownerRobloxUserId: input.robloxUserId,
      token: crypto.randomUUID(),
      grantedAtMs: now,
      expiresAtMs: now + input.ttlMs
    };

    this.locks.set(key, lock);
    return { granted: true, lock };
  }

  heartbeat(input: {
    placeId: number;
    jobId: string;
    frequency: string;
    robloxUserId: number;
    token: string;
    ttlMs: number;
  }): boolean {
    const now = Date.now();
    const lock = this.locks.get(this.key(input.placeId, input.jobId, input.frequency));

    if (!lock) return false;
    if (lock.ownerRobloxUserId !== input.robloxUserId) return false;
    if (lock.token !== input.token) return false;

    lock.expiresAtMs = now + input.ttlMs;
    return true;
  }

  release(input: {
    placeId: number;
    jobId: string;
    frequency: string;
    robloxUserId: number;
    token: string;
  }): boolean {
    const key = this.key(input.placeId, input.jobId, input.frequency);
    const lock = this.locks.get(key);

    if (!lock) return false;
    if (lock.ownerRobloxUserId !== input.robloxUserId) return false;
    if (lock.token !== input.token) return false;

    this.locks.delete(key);
    return true;
  }

  listForServer(placeId: number, jobId: string): TxLock[] {
    const now = Date.now();

    return [...this.locks.values()].filter(
      (lock) =>
        lock.placeId === placeId &&
        lock.jobId === jobId &&
        lock.expiresAtMs > now
    );
  }

  pruneExpired(): number {
    const now = Date.now();
    let removed = 0;

    for (const [key, lock] of this.locks) {
      if (lock.expiresAtMs <= now) {
        this.locks.delete(key);
        removed++;
      }
    }

    return removed;
  }

  private key(placeId: number, jobId: string, frequency: string): string {
    return `${placeId}:${jobId}:${frequency}`;
  }
}