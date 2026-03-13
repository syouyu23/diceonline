const fs = require("fs");
const path = require("path");
const http = require("http");
const WebSocket = require("ws");
const sqlite3 = require("sqlite3").verbose();
require("dotenv").config();

const PORT = parseInt(process.env.PORT || "8080", 10);
const RANDOM_MIN = 0;
const RANDOM_MAX = 65535;
const RANDOM_RANGE = RANDOM_MAX - RANDOM_MIN + 1;
const RESET_DELAY_SEC = parseInt(process.env.RESET_DELAY_SEC || "60", 10);
const DB_PATH = process.env.DB_PATH || "./data/game.db";

fs.mkdirSync(path.dirname(DB_PATH), { recursive: true });

const db = new sqlite3.Database(DB_PATH);

function run(sql, params = []) {
  return new Promise((resolve, reject) => {
    db.run(sql, params, function (err) {
      if (err) return reject(err);
      resolve(this);
    });
  });
}

function get(sql, params = []) {
  return new Promise((resolve, reject) => {
    db.get(sql, params, (err, row) => {
      if (err) return reject(err);
      resolve(row);
    });
  });
}

function randomId() {
  return Math.random().toString(36).slice(2, 10);
}

function rollNumber() {
  return Math.floor(Math.random() * RANDOM_RANGE) + RANDOM_MIN;
}

async function start() {
  await run(
    "CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
  );
  await run(
    "CREATE TABLE IF NOT EXISTS shared (roll INTEGER PRIMARY KEY, created_at INTEGER NOT NULL, first_finder_name TEXT NOT NULL, first_finder_id TEXT NOT NULL)"
  );
  await run(
    "CREATE TABLE IF NOT EXISTS personal (player_id TEXT NOT NULL, roll INTEGER NOT NULL, PRIMARY KEY(player_id, roll))"
  );
  await run(
    "CREATE TABLE IF NOT EXISTS players (player_id TEXT PRIMARY KEY, name TEXT NOT NULL, updated_at INTEGER NOT NULL)"
  );
  await run(
    "CREATE TABLE IF NOT EXISTS roll_stats (roll INTEGER PRIMARY KEY, count INTEGER NOT NULL, last_seen INTEGER NOT NULL)"
  );
  await run(
    "CREATE TABLE IF NOT EXISTS finder_stats (player_id TEXT PRIMARY KEY, count INTEGER NOT NULL, reached_at INTEGER NOT NULL)"
  );

  const storedRangeRow = await get(
    "SELECT value FROM meta WHERE key = ?",
    ["random_range"]
  );
  const storedSeasonRow = await get(
    "SELECT value FROM meta WHERE key = ?",
    ["season_id"]
  );
  const storedSchemaRow = await get(
    "SELECT value FROM meta WHERE key = ?",
    ["schema_version"]
  );

  let seasonId = storedSeasonRow ? parseInt(storedSeasonRow.value, 10) : 1;
  const schemaVersion = storedSchemaRow
    ? parseInt(storedSchemaRow.value, 10)
    : 1;
  const requiredSchemaVersion = 4;

  if (schemaVersion < requiredSchemaVersion) {
    await run("DROP TABLE IF EXISTS shared");
    await run("DROP TABLE IF EXISTS personal");
    await run("DROP TABLE IF EXISTS players");
    await run("DROP TABLE IF EXISTS roll_stats");
    await run("DROP TABLE IF EXISTS finder_stats");
    await run(
      "CREATE TABLE IF NOT EXISTS shared (roll INTEGER PRIMARY KEY, created_at INTEGER NOT NULL, first_finder_name TEXT NOT NULL, first_finder_id TEXT NOT NULL)"
    );
    await run(
      "CREATE TABLE IF NOT EXISTS personal (player_id TEXT NOT NULL, roll INTEGER NOT NULL, PRIMARY KEY(player_id, roll))"
    );
    await run(
      "CREATE TABLE IF NOT EXISTS players (player_id TEXT PRIMARY KEY, name TEXT NOT NULL, updated_at INTEGER NOT NULL)"
    );
    await run(
      "CREATE TABLE IF NOT EXISTS roll_stats (roll INTEGER PRIMARY KEY, count INTEGER NOT NULL, last_seen INTEGER NOT NULL)"
    );
    await run(
      "CREATE TABLE IF NOT EXISTS finder_stats (player_id TEXT PRIMARY KEY, count INTEGER NOT NULL, reached_at INTEGER NOT NULL)"
    );
    await run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [
      "schema_version",
      String(requiredSchemaVersion),
    ]);
  }

  if (!storedRangeRow) {
    await run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [
      "random_range",
      String(RANDOM_RANGE),
    ]);
    await run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [
      "season_id",
      String(seasonId),
    ]);
    await run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [
      "schema_version",
      String(requiredSchemaVersion),
    ]);
  } else if (parseInt(storedRangeRow.value, 10) !== RANDOM_RANGE) {
    await run("DELETE FROM shared");
    await run("DELETE FROM personal");
    await run("DELETE FROM players");
    await run("DELETE FROM roll_stats");
    await run("DELETE FROM finder_stats");
    seasonId += 1;
    await run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [
      "random_range",
      String(RANDOM_RANGE),
    ]);
    await run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [
      "season_id",
      String(seasonId),
    ]);
  }

  let sharedCountRow = await get("SELECT COUNT(*) AS c FROM shared");
  let sharedCount = sharedCountRow ? sharedCountRow.c : 0;
  const total = RANDOM_RANGE;

  let ending = false;
  let resetAt = 0;
  let resetTimer = null;

  const server = http.createServer();
  const wss = new WebSocket.Server({ server });
  const clients = new Map();

  async function getPersonalCount(playerId) {
    const row = await get(
      "SELECT COUNT(*) AS c FROM personal WHERE player_id = ?",
      [playerId]
    );
    return row ? row.c : 0;
  }

  async function getPlayerName(playerId) {
    const row = await get(
      "SELECT name FROM players WHERE player_id = ?",
      [playerId]
    );
    return row ? row.name : "";
  }

  async function getLatestRollsWithStats(limit) {
    const rows = await new Promise((resolve, reject) => {
      db.all(
        "SELECT s.roll, s.first_finder_name, s.first_finder_id, s.created_at AS first_at, rs.count, rs.last_seen FROM shared s JOIN roll_stats rs ON s.roll = rs.roll ORDER BY rs.last_seen DESC LIMIT ?",
        [limit],
        (err, data) => {
          if (err) return reject(err);
          resolve(data || []);
        }
      );
    });
    return rows.map((r) => ({
      roll: r.roll,
      count: r.count,
      last_seen: r.last_seen,
      first_finder_name: r.first_finder_name,
      first_finder_id: r.first_finder_id,
      first_at: r.first_at,
    }));
  }

  async function getLeaderboard(limit) {
    const rows = await new Promise((resolve, reject) => {
      db.all(
        "SELECT f.player_id, f.count, f.reached_at, p.name FROM finder_stats f JOIN players p ON f.player_id = p.player_id ORDER BY f.count DESC, f.reached_at ASC LIMIT ?",
        [limit],
        (err, data) => {
          if (err) return reject(err);
          resolve(data || []);
        }
      );
    });
    return rows.map((r) => ({
      player_id: r.player_id,
      name: r.name,
      count: r.count,
      reached_at: r.reached_at,
    }));
  }

  function send(ws, type, data) {
    if (ws.readyState !== WebSocket.OPEN) return;
    ws.send(JSON.stringify({ type, data }));
  }

  function broadcast(type, data) {
    for (const ws of clients.keys()) {
      send(ws, type, data);
    }
  }

  async function doReset(reason) {
    await run("DELETE FROM shared");
    await run("DELETE FROM personal");
    await run("DELETE FROM players");
    await run("DELETE FROM roll_stats");
    await run("DELETE FROM finder_stats");
    sharedCount = 0;
    seasonId += 1;
    await run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [
      "season_id",
      String(seasonId),
    ]);
    ending = false;
    resetAt = 0;
    if (resetTimer) {
      clearTimeout(resetTimer);
      resetTimer = null;
    }
    broadcast("reset", {
      random_min: RANDOM_MIN,
      random_max: RANDOM_MAX,
      season_id: seasonId,
      shared_count: sharedCount,
      total,
      reason,
      latest_rolls: [],
      leaderboard: [],
    });
  }

  function triggerEnding() {
    if (ending) return;
    ending = true;
    resetAt = Date.now() + RESET_DELAY_SEC * 1000;
    broadcast("ending", {
      season_id: seasonId,
      reset_at: resetAt,
    });
    resetTimer = setTimeout(() => {
      doReset("ending_complete").catch(() => {});
    }, RESET_DELAY_SEC * 1000);
  }

  wss.on("connection", async (ws) => {
    const playerId = randomId();
    clients.set(ws, {
      playerId,
      personalCount: 0,
      hasSnapshot: false,
      playerName: "",
    });

    const sendSnapshot = async () => {
      const client = clients.get(ws);
      if (!client || client.hasSnapshot) return;
      client.personalCount = await getPersonalCount(client.playerId);
      client.playerName = await getPlayerName(client.playerId);
      const latestRolls = await getLatestRollsWithStats(100);
      const leaderboard = await getLeaderboard(20);
      client.hasSnapshot = true;
      send(ws, "snapshot", {
        player_id: client.playerId,
        player_name: client.playerName,
        random_min: RANDOM_MIN,
        random_max: RANDOM_MAX,
        season_id: seasonId,
        shared_count: sharedCount,
        personal_count: client.personalCount,
        total,
        ending,
        reset_at: resetAt,
        latest_rolls: latestRolls,
        leaderboard,
      });
    };

    setTimeout(() => {
      sendSnapshot().catch(() => {});
    }, 300);

    ws.on("message", async (raw) => {
      let msg;
      try {
        msg = JSON.parse(raw.toString());
      } catch {
        return;
      }
      if (!msg || typeof msg.type !== "string") return;
      if (msg.type === "hello") {
        const payload = msg.data || {};
        if (payload && typeof payload.player_id === "string") {
          const client = clients.get(ws);
          if (client) {
            client.playerId = payload.player_id;
            if (typeof payload.player_name === "string") {
              client.playerName = payload.player_name;
              const now = Date.now();
              await run(
                "INSERT INTO players(player_id, name, updated_at) VALUES(?, ?, ?) ON CONFLICT(player_id) DO UPDATE SET name=excluded.name, updated_at=excluded.updated_at",
                [client.playerId, client.playerName, now]
              );
            } else {
              client.playerName = await getPlayerName(client.playerId);
            }
            client.personalCount = await getPersonalCount(client.playerId);
            const latestRolls = await getLatestRollsWithStats(100);
            const leaderboard = await getLeaderboard(20);
            client.hasSnapshot = true;
            send(ws, "snapshot", {
              player_id: client.playerId,
              player_name: client.playerName,
              random_min: RANDOM_MIN,
              random_max: RANDOM_MAX,
              season_id: seasonId,
              shared_count: sharedCount,
              personal_count: client.personalCount,
              total,
              ending,
              reset_at: resetAt,
              latest_rolls: latestRolls,
              leaderboard,
            });
          }
        }
        return;
      }
      if (msg.type === "roll_request") {
        if (ending) {
          send(ws, "error", { code: "ending", message: "Game is ending." });
          return;
        }
        const roll = rollNumber();
        const finderName =
          clients.get(ws)?.playerName && clients.get(ws)?.playerName.length > 0
            ? clients.get(ws)?.playerName
            : "anonymous";
        const finderId = clients.get(ws)?.playerId || playerId;
        const now = Date.now();
        let newShared = false;
        try {
          await run(
            "INSERT INTO shared(roll, created_at, first_finder_name, first_finder_id) VALUES(?, ?, ?, ?)",
            [roll, now, finderName, finderId]
          );
          newShared = true;
          sharedCount += 1;
        } catch {
          newShared = false;
        }

        await run(
          "INSERT INTO roll_stats(roll, count, last_seen) VALUES(?, 1, ?) ON CONFLICT(roll) DO UPDATE SET count = count + 1, last_seen = excluded.last_seen",
          [roll, now]
        );

        let newPersonal = false;
        try {
          await run("INSERT INTO personal(player_id, roll) VALUES(?, ?)", [
            clients.get(ws)?.playerId || playerId,
            roll,
          ]);
          newPersonal = true;
          const client = clients.get(ws);
          if (client) client.personalCount += 1;
        } catch {
          newPersonal = false;
        }

        const client = clients.get(ws);
        send(ws, "roll_result", {
          roll,
          is_new_shared: newShared,
          is_new_personal: newPersonal,
          shared_count: sharedCount,
          personal_count: client ? client.personalCount : 0,
          total,
        });

        let leaderboard = null;
        if (newShared) {
          await run(
            "INSERT INTO finder_stats(player_id, count, reached_at) VALUES(?, 1, ?) ON CONFLICT(player_id) DO UPDATE SET count = count + 1, reached_at = excluded.reached_at",
            [finderId, now]
          );
          leaderboard = await getLeaderboard(20);
        }
        const statRow = await get(
          "SELECT count, last_seen FROM roll_stats WHERE roll = ?",
          [roll]
        );
        const firstRow = await get(
          "SELECT first_finder_name FROM shared WHERE roll = ?",
          [roll]
        );
        const firstFinderName = firstRow ? firstRow.first_finder_name : "";
        const updatePayload = {
          roll,
          shared_count: sharedCount,
          total,
          season_id: seasonId,
          created_at: now,
          finder_name: firstFinderName,
          count: statRow ? statRow.count : 1,
          last_seen: statRow ? statRow.last_seen : now,
        };
        if (leaderboard) {
          updatePayload.leaderboard = leaderboard;
        }
        broadcast("shared_update", updatePayload);

        if (sharedCount >= total) {
          triggerEnding();
        }
      }
    });

    ws.on("close", () => {
      clients.delete(ws);
    });
  });

  server.listen(PORT, () => {
    console.log(`Server listening on :${PORT}`);
  });
}

start().catch((err) => {
  console.error(err);
  process.exit(1);
});
