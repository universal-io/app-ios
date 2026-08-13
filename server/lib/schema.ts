/**
 * The analysis wire contract. Coordinates are always normalized floats in the
 * image's own space (0-1, origin top-left) so the client never has to know what
 * resolution the model saw. See docs/architecture.md section 4.
 */

export type Box = { x: number; y: number; w: number; h: number };

export type Annotation = {
  id: string;
  kind: "highlight" | "callout";
  box: Box;
  label: string;
  candidate_id: string | null;
};

export type AnalyzeResult = {
  summary: string;
  annotations: Annotation[];
};

export type Candidate = {
  id: string;
  role: string;
  label: string;
  box: Box;
};

export type AnalyzeSource = {
  kind: "mirror" | "camera";
  app_name?: string;
  window_title?: string;
  candidates?: Candidate[];
};

export type Turn = { role: "user" | "assistant"; text: string };

export type AnalyzeRequest = {
  request_id: string;
  image: string;
  image_media_type?: string;
  question?: string;
  tap_point?: { x: number; y: number };
  turns?: Turn[];
  context_pack_id?: string;
  source?: AnalyzeSource;
  client?: { platform: string; app_version: string };
};

const BOX_SCHEMA = {
  type: "object",
  description:
    "Rectangle in normalized image coordinates. Origin is the top-left of the image; all four values are fractions between 0 and 1.",
  properties: {
    x: { type: "number", description: "Left edge as a fraction of image width." },
    y: { type: "number", description: "Top edge as a fraction of image height." },
    w: { type: "number", description: "Width as a fraction of image width." },
    h: { type: "number", description: "Height as a fraction of image height." },
  },
  required: ["x", "y", "w", "h"],
  additionalProperties: false,
} as const;

/**
 * `summary` is deliberately the first property: the server streams it to the
 * client as it arrives, so the user sees prose before the annotations finish.
 */
export const ANALYZE_JSON_SCHEMA = {
  type: "object",
  properties: {
    summary: {
      type: "string",
      description:
        "The explanation shown to the user. Written in the user's language, addressed to someone who is looking at this screen right now.",
    },
    annotations: {
      type: "array",
      description:
        "Places on the screen to draw attention to. Empty when the answer does not point at anything.",
      items: {
        type: "object",
        properties: {
          id: { type: "string", description: "Unique within this response." },
          kind: {
            type: "string",
            enum: ["highlight", "callout"],
            description:
              "highlight draws a box around a target; callout attaches a note to a region.",
          },
          box: BOX_SCHEMA,
          label: {
            type: "string",
            description: "Short text drawn next to the box. A few words at most.",
          },
          candidate_id: {
            type: ["string", "null"],
            description:
              "The id of the supplied screen-structure candidate this annotation refers to, or null when no candidate list was supplied or none matched.",
          },
        },
        required: ["id", "kind", "box", "label", "candidate_id"],
        additionalProperties: false,
      },
    },
  },
  required: ["summary", "annotations"],
  additionalProperties: false,
} as const;

export function isAnalyzeResult(value: unknown): value is AnalyzeResult {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as Partial<AnalyzeResult>;
  if (typeof candidate.summary !== "string") return false;
  if (!Array.isArray(candidate.annotations)) return false;
  return candidate.annotations.every((annotation) => {
    if (typeof annotation !== "object" || annotation === null) return false;
    const box = (annotation as Annotation).box;
    return (
      typeof (annotation as Annotation).id === "string" &&
      typeof (annotation as Annotation).label === "string" &&
      typeof box === "object" &&
      box !== null &&
      ["x", "y", "w", "h"].every((k) => typeof (box as never)[k] === "number")
    );
  });
}

/**
 * Clamps boxes into the image. A model that overshoots the edge should still
 * produce a drawable annotation rather than one the client silently drops.
 */
export function clampResult(result: AnalyzeResult): AnalyzeResult {
  return {
    summary: result.summary,
    annotations: result.annotations.map((annotation) => {
      const x = Math.min(Math.max(annotation.box.x, 0), 1);
      const y = Math.min(Math.max(annotation.box.y, 0), 1);
      return {
        ...annotation,
        box: {
          x,
          y,
          w: Math.min(Math.max(annotation.box.w, 0), 1 - x),
          h: Math.min(Math.max(annotation.box.h, 0), 1 - y),
        },
      };
    }),
  };
}
