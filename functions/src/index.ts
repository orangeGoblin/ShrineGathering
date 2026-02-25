import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { HttpsError, onCall } from "firebase-functions/v2/https";

initializeApp();

type DetectShrineInput = {
  lat: number;
  lng: number;
  text?: string;
};

type GenerateCaptionsInput = {
  shrineName: string;
  text: string;
  metadata?: {
    goshuin?: boolean;
  };
};

function assertNumber(value: unknown, field: string): asserts value is number {
  if (typeof value !== "number" || Number.isNaN(value) || !Number.isFinite(value)) {
    throw new HttpsError("invalid-argument", `${field} must be a finite number`);
  }
}

function toRadians(deg: number) {
  return (deg * Math.PI) / 180;
}

function distanceMeters(lat1: number, lng1: number, lat2: number, lng2: number) {
  // Haversine
  const R = 6371000;
  const dLat = toRadians(lat2 - lat1);
  const dLng = toRadians(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(toRadians(lat1)) * Math.cos(toRadians(lat2)) * Math.sin(dLng / 2) * Math.sin(dLng / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

export const detectShrine = onCall(async (request) => {
  const data = request.data as Partial<DetectShrineInput> | undefined;
  if (!data) throw new HttpsError("invalid-argument", "data is required");

  assertNumber(data.lat, "lat");
  assertNumber(data.lng, "lng");

  const lat = data.lat;
  const lng = data.lng;
  const radiusMeters = 1000;

  // Firestoreは緯度・経度の両方の範囲クエリができないため、
  // まず緯度の範囲だけで絞ってからコード側で距離計算します（MVP向け）。
  const deltaLat = radiusMeters / 111_320; // おおよそ: 1度あたり111.32km
  const minLat = lat - deltaLat;
  const maxLat = lat + deltaLat;

  const db = getFirestore();
  const snapshot = await db
    .collection("shrines")
    .where("lat", ">=", minLat)
    .where("lat", "<=", maxLat)
    .limit(200)
    .get();

  let best:
    | {
        shrineId: string;
        name: string | null;
        prefecture: string | null;
        lat: number;
        lng: number;
        distanceMeters: number;
      }
    | null = null;

  for (const doc of snapshot.docs) {
    const s = doc.data() as Partial<{ name: unknown; prefecture: unknown; lat: unknown; lng: unknown }>;
    if (typeof s.lat !== "number" || typeof s.lng !== "number") continue;

    const d = distanceMeters(lat, lng, s.lat, s.lng);
    if (d > radiusMeters) continue;

    if (!best || d < best.distanceMeters) {
      best = {
        shrineId: doc.id,
        name: typeof s.name === "string" ? s.name : null,
        prefecture: typeof s.prefecture === "string" ? s.prefecture : null,
        lat: s.lat,
        lng: s.lng,
        distanceMeters: d,
      };
    }
  }

  // Flutter 側の期待フォーマット:
  // {
  //   "shrineId": "...",
  //   "name": "明治神宮",
  //   "distance": 120
  // }
  if (!best) {
    return {
      shrineId: null,
      name: null,
      distance: null,
    };
  }

  return {
    shrineId: best.shrineId,
    name: best.name,
    distance: Math.round(best.distanceMeters),
  };
});

export const generateCaptions = onCall(async (request) => {
  const data = request.data as Partial<GenerateCaptionsInput> | undefined;
  if (!data) throw new HttpsError("invalid-argument", "data is required");
  if (typeof data.shrineName !== "string" || data.shrineName.trim() === "") {
    throw new HttpsError("invalid-argument", "shrineName is required");
  }
  if (typeof data.text !== "string") {
    throw new HttpsError("invalid-argument", "text is required");
  }

  const shrineName = data.shrineName.trim();
  const text = data.text.trim();
  const goshuin = Boolean(data.metadata?.goshuin);

  // OpenAI連携は後続で実装（まずはMVP用のテンプレ生成を返す）
  const base = [
    `⛩️ ${shrineName} に参拝しました。`,
    text ? text : null,
    goshuin ? "御朱印もいただきました。" : null,
  ]
    .filter(Boolean)
    .join("\n");

  const hashtags = ["#神社", "#参拝", `#${shrineName.replace(/\s+/g, "")}`].join(" ");

  const instagramCaption = `${base}\n\n${hashtags}`;
  const xCaption = `${base}\n${hashtags}`.slice(0, 280);
  const threadsCaption = instagramCaption;

  return { instagramCaption, xCaption, threadsCaption };
});

export const postToSNS = onCall(async () => {
  // SNS API連携はアクセストークンや審査が必要なため、まずは関数の形だけ用意。
  // 入力仕様（例）: { postId, targets: { x: true, instagram: true }, ... }
  return {
    posted: {
      x: false,
      instagram: false,
      threads: false,
    },
    errors: [
      {
        code: "not-implemented",
        message: "SNS posting is not implemented yet.",
      },
    ],
  };
});

