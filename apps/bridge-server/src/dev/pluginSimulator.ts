type PluginSnapshot = {
  nowMs: number;
  localRobloxUserId: number;
  players: Array<{
    robloxUserId: number;
    displayName?: string;
    frequency: string;
    isPtt: boolean;
    position: { x: number; y: number; z: number };
  }>;
  txLocks: Array<{
    frequency: string;
    ownerRobloxUserId: number;
    expiresAtMs: number;
  }>;
};

const baseUrl = "http://localhost:3000";
const placeId = 16489784096;
const jobId = "studio-local";
const localRobloxUserId = 2026345646;

async function main() {
  const url =
    `${baseUrl}/v1/plugin/snapshot` +
    `?placeId=${placeId}` +
    `&jobId=${encodeURIComponent(jobId)}` +
    `&localRobloxUserId=${localRobloxUserId}`;

  setInterval(async () => {
    try {
      const res = await fetch(url);
      const snapshot = (await res.json()) as PluginSnapshot;

      const me = snapshot.players.find(
        (p) => p.robloxUserId === localRobloxUserId
      );

      if (!me) {
        console.log("Local player not found in snapshot");
        return;
      }

      const myFrequency = me.frequency;

      const activeLock = snapshot.txLocks.find(
        (lock) => lock.frequency === myFrequency
      );

      if (!activeLock) {
        console.log(`[${myFrequency}] idle`);
        return;
      }

      if (activeLock.ownerRobloxUserId === localRobloxUserId) {
        console.log(`[${myFrequency}] I am transmitting`);
        return;
      }

      const speaker = snapshot.players.find(
        (p) => p.robloxUserId === activeLock.ownerRobloxUserId
      );

      console.log(
        `[${myFrequency}] receiving from ${
          speaker?.displayName ?? activeLock.ownerRobloxUserId
        }`
      );
    } catch (err) {
      console.error("Simulator error:", err);
    }
  }, 200);
}

main();