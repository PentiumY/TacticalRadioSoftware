const baseUrl = "http://localhost:3000";

let x = 0;

async function sendState() {
  x += 1;

  const body = {
    placeId: 123,
    jobId: "test-server-1",
    players: [
      {
        robloxUserId: 111,
        displayName: "PlayerOne",
        position: { x, y: 5, z: 0 },
        lookVector: { x: 0, y: 0, z: -1 },
        frequency: "30.125",
        isPtt: false,
        team: "BLUFOR",
        squad: "Alpha",
        radioId: "primary"
      },
      {
        robloxUserId: 222,
        displayName: "PlayerTwo",
        position: { x: 25, y: 5, z: 0 },
        lookVector: { x: 0, y: 0, z: -1 },
        frequency: "30.125",
        isPtt: false,
        team: "BLUFOR",
        squad: "Alpha",
        radioId: "primary"
      }
    ]
  };

  const res = await fetch(`${baseUrl}/v1/roblox/state`, {
    method: "POST",
    headers: {
      "content-type": "application/json"
    },
    body: JSON.stringify(body)
  });

  if (!res.ok) {
    console.error("Failed to send state:", res.status, await res.text());
    return;
  }

  console.log("Sent fake Roblox state");
}

setInterval(() => {
  sendState().catch(console.error);
}, 200);