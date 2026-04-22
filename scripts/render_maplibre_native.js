#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");
const zlib = require("node:zlib");

const mbgl = require("@maplibre/maplibre-gl-native");
const initSqlJs = require("sql.js");

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i += 1) {
    const key = argv[i];
    if (!key.startsWith("--")) {
      continue;
    }
    const value = argv[i + 1];
    args[key.slice(2)] = value;
    i += 1;
  }
  return args;
}

function requireArg(args, name) {
  const value = args[name];
  if (!value) {
    console.error(`[error] Fehlender Parameter --${name}`);
    process.exit(1);
  }
  return value;
}

async function main() {
  const args = parseArgs(process.argv);

  if (args.capabilities === "1") {
    process.stdout.write(`${JSON.stringify({ healthcheck: true, render: true, worker: true })}\n`);
    process.exit(0);
  }

  if (args.healthcheck === "1") {
    try {
      require("@maplibre/maplibre-gl-native");
      require("sql.js");
    } catch (_err) {
      console.error("[error] Paket @maplibre/maplibre-gl-native oder sql.js ist nicht installiert.");
      process.exit(2);
    }
    process.stdout.write("ok\n");
    process.exit(0);
  }

  requireArg(args, "input");
  requireArg(args, "style");
  requireArg(args, "gpu");

  const workerMode = args.worker === "1";
  if (!workerMode) {
    requireArg(args, "z");
    requireArg(args, "x");
    requireArg(args, "y");
  }

  const inputPath = path.resolve(args.input);
  const styleName = args.style;
  const assetsRoot = args["assets-root"] ? path.resolve(args["assets-root"]) : path.dirname(inputPath);

  const stylePath = path.join(assetsRoot, "styles", styleName, "style.json");
  if (!fs.existsSync(stylePath)) {
    console.error(`[error] style.json nicht gefunden: ${stylePath}`);
    process.exit(1);
  }

  let style;
  try {
    style = JSON.parse(fs.readFileSync(stylePath, "utf-8"));
  } catch (err) {
    console.error(`[error] style.json kann nicht gelesen werden: ${err.message}`);
    process.exit(1);
  }

  const runtime = await createRuntime({ inputPath, assetsRoot, style, styleName });

  if (workerMode) {
    startWorker(runtime);
    return;
  }

  const z = Number.parseInt(args.z, 10);
  const x = Number.parseInt(args.x, 10);
  const y = Number.parseInt(args.y, 10);
  if (!Number.isInteger(z) || !Number.isInteger(x) || !Number.isInteger(y)) {
    runtime.close();
    console.error("[error] Ungueltige Tile-Koordinaten (z/x/y)");
    process.exit(1);
  }

  try {
    const buffer = await renderTile(runtime.map, z, x, y);
    process.stdout.write(buffer);
  } catch (err) {
    console.error(`[error] map.render fehlgeschlagen: ${err.message}`);
    process.exit(1);
  } finally {
    runtime.close();
  }
}

async function createRuntime(options) {
  const normalizedStyle = normalizeStyle(options.style, options.styleName);
  const SQL = await initSqlJs({
    locateFile: (file) => path.join(path.dirname(require.resolve("sql.js")), file),
  });
  const dbBuffer = fs.readFileSync(options.inputPath);
  const db = new SQL.Database(new Uint8Array(dbBuffer));
  const metadata = readMetadata(db);

  const request = (req, callback) => {
    try {
      if (req.url.startsWith("local://")) {
        const filePath = resolveLocalPath(options.assetsRoot, req.url);
        callback(null, { data: fs.readFileSync(filePath) });
        return;
      }

      if (req.url.startsWith("mbtiles://")) {
        if (isSourceRequest(req.url)) {
          const tileJson = buildTileJson(metadata);
          callback(null, { data: Buffer.from(JSON.stringify(tileJson), "utf-8") });
          return;
        }
        const data = readVectorTile(db, req.url);
        if (!data) {
          callback(new Error(`Tile nicht gefunden: ${req.url}`));
          return;
        }
        callback(null, { data });
        return;
      }

      callback(new Error(`Nicht unterstuetzte URL im Request-Handler: ${req.url}`));
    } catch (err) {
      callback(err);
    }
  };

  const map = new mbgl.Map({ request, ratio: 1.0 });
  map.load(normalizedStyle);

  return {
    map,
    close: () => {
      try {
        db.close();
      } catch (_dbErr) {
        // ignore close errors
      }
      if (typeof map.release === "function") {
        try {
          map.release();
        } catch (_releaseErr) {
          // ignore release errors
        }
      }
    },
  };
}

function startWorker(runtime) {
  process.stdout.write(`${JSON.stringify({ ready: true })}\n`);

  const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  let queue = Promise.resolve();

  rl.on("line", (line) => {
    queue = queue.then(async () => {
      let req;
      try {
        req = JSON.parse(line);
      } catch (_err) {
        process.stdout.write(`${JSON.stringify({ ok: false, error: "Ungueltiges JSON" })}\n`);
        return;
      }

      const id = req.id;
      const z = Number.parseInt(req.z, 10);
      const x = Number.parseInt(req.x, 10);
      const y = Number.parseInt(req.y, 10);
      if (!Number.isInteger(z) || !Number.isInteger(x) || !Number.isInteger(y)) {
        process.stdout.write(`${JSON.stringify({ id, ok: false, error: "Ungueltige Tile-Koordinaten" })}\n`);
        return;
      }

      try {
        const buffer = await renderTile(runtime.map, z, x, y);
        process.stdout.write(`${JSON.stringify({ id, ok: true, png: Buffer.from(buffer).toString("base64") })}\n`);
      } catch (err) {
        process.stdout.write(`${JSON.stringify({ id, ok: false, error: err.message })}\n`);
      }
    });
  });

  rl.on("close", () => {
    runtime.close();
    process.exit(0);
  });
}

function renderTile(map, z, x, y) {
  return new Promise((resolve, reject) => {
    const center = xyzTileCenter(z, x, y);
    map.render(
      {
        zoom: z,
        center,
        width: 256,
        height: 256,
        bearing: 0,
        pitch: 0,
      },
      (err, buffer) => {
        if (err) {
          reject(err);
          return;
        }
        resolve(buffer);
      }
    );
  });
}

function normalizeStyle(style, styleName) {
  const normalized = JSON.parse(JSON.stringify(style));

  if (typeof normalized.glyphs === "string") {
    normalized.glyphs = normalized.glyphs.startsWith("local://")
      ? normalized.glyphs
      : `local://fonts/${normalized.glyphs.replace(/^\/+/, "")}`;
  }

  if (typeof normalized.sprite === "string") {
    normalized.sprite = normalized.sprite
      .replace("{styleJsonFolder}", `local://styles/${styleName}`)
      .replace(/^\/+/, "");
    if (!normalized.sprite.startsWith("local://")) {
      normalized.sprite = `local://${normalized.sprite}`;
    }
  }

  if (normalized.sources && typeof normalized.sources === "object") {
    Object.keys(normalized.sources).forEach((key) => {
      const source = normalized.sources[key];
      if (source && source.type === "vector" && typeof source.url === "string") {
        source.url = source.url.replace("mbtiles://{openmaptiles}", "mbtiles://openmaptiles");
      }
    });
  }

  return normalized;
}

function resolveLocalPath(assetsRoot, url) {
  const withoutScheme = url.slice("local://".length);
  const decoded = decodeURIComponent(withoutScheme);
  return path.join(assetsRoot, decoded);
}

function readVectorTile(db, url) {
  const cleanUrl = url.split("?")[0];
  const match = cleanUrl.match(/^mbtiles:\/\/[^/]+\/(\d+)\/(\d+)\/(\d+)\.(?:pbf|mvt)$/i);
  if (!match) {
    return null;
  }

  const z = Number.parseInt(match[1], 10);
  const x = Number.parseInt(match[2], 10);
  const y = Number.parseInt(match[3], 10);
  const tmsY = (1 << z) - 1 - y;
  const sql = `SELECT tile_data FROM tiles WHERE zoom_level = ${z} AND tile_column = ${x} AND tile_row = ${tmsY}`;
  const rows = db.exec(sql);
  if (!rows || rows.length === 0 || !rows[0].values || rows[0].values.length === 0) {
    return null;
  }

  const raw = rows[0].values[0][0];
  if (!raw) {
    return null;
  }

  const data = Buffer.from(raw);
  if (data.length >= 2 && data[0] === 0x1f && data[1] === 0x8b) {
    return zlib.gunzipSync(data);
  }
  return data;
}

function xyzTileCenter(z, x, y) {
  const n = 2 ** z;
  const lon = ((x + 0.5) / n) * 360 - 180;
  const latRad = Math.atan(Math.sinh(Math.PI * (1 - (2 * (y + 0.5)) / n)));
  const lat = (latRad * 180) / Math.PI;
  return [lon, lat];
}

function isSourceRequest(url) {
  return /^mbtiles:\/\/[^/?]+(?:\?.*)?$/i.test(url);
}

function readMetadata(db) {
  const result = {};
  const stmt = db.prepare("SELECT name, value FROM metadata");
  while (stmt.step()) {
    const row = stmt.getAsObject();
    if (row && row.name) {
      result[String(row.name)] = String(row.value ?? "");
    }
  }
  stmt.free();
  return result;
}

function buildTileJson(metadata) {
  const minzoom = Number.parseInt(metadata.minzoom || "0", 10);
  const maxzoom = Number.parseInt(metadata.maxzoom || "14", 10);
  const bounds = metadata.bounds || "-180,-85,180,85";
  return {
    tilejson: "2.2.0",
    name: metadata.name || "openmaptiles",
    format: "pbf",
    scheme: "xyz",
    minzoom: Number.isFinite(minzoom) ? minzoom : 0,
    maxzoom: Number.isFinite(maxzoom) ? maxzoom : 14,
    bounds: bounds.split(",").map((x) => Number.parseFloat(x.trim())),
    tiles: ["mbtiles://openmaptiles/{z}/{x}/{y}.pbf"],
  };
}

main().catch((err) => {
  console.error(`[error] maplibre helper crashed: ${err.message}`);
  process.exit(1);
});
