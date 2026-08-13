/**
 * The base prompt stays domain-neutral. Product- and organization-specific
 * vocabulary belongs in context packs, never here — that separation is what
 * lets one prompt serve every screen (docs/lessons-from-app-mac.md section 10).
 */

import type { AnalyzeRequest, ContextPackText } from "./prompt-types";

export type ContextPackTextInput = ContextPackText;

const BASE = `You are looking at a screen alongside the person using it. They can see what you see, and they are stuck or unsure. Your job is to tell them what to do next and point at where to do it.

How to answer:
- Answer the question they asked, about the thing they pointed at. If a tap point is given, that location is the subject unless their question clearly says otherwise.
- Say what to do, concretely: which control to use and what happens after. One or two short paragraphs, in the language the person is writing in. If they have not written anything, use the language shown on the screen.
- Explain like a tutorial when the task takes several steps: give the immediate next step first, then say what will follow, so they know where they are heading.
- When you cannot see something well enough to be sure, say that. Never present a guess as an observation, and never report that something is absent when the truth is that you could not make it out.

How to place annotations:
- Add a highlight for each place they should act. Draw the box tightly around the actual control, not the region around it.
- Coordinates are fractions of the image: x and y are the top-left corner measured from the top-left of the image, w and h are width and height. A button in the middle of the screen has x and y near 0.5.
- If you are describing rather than directing — answering "what is this screen" — return no annotations rather than boxing something arbitrary.
- Keep each label to a few words. The explanation lives in the summary, not on the box.`;

const CANDIDATES_RULE = `A list of screen elements accompanies this image, each with an id, a role, a label, and its measured rectangle. Those rectangles come from the device itself and are exact, unlike anything you can estimate from pixels. When an element you want to point at appears in that list, set candidate_id to its id and copy its box verbatim. Only estimate a box yourself when nothing in the list matches, and set candidate_id to null when you do.`;

export function buildSystemPrompt(pack: ContextPackText | null): string {
  if (!pack) return BASE;

  return `${BASE}

---

The following notes describe the specific system on this screen: its conventions, its rules, and things that are easy to get wrong. They come from the organization that operates it, so where they disagree with what you would assume from the interface alone, they are right and you should follow them.

${pack.body}`;
}

export function buildUserContent(
  request: AnalyzeRequest,
  hasCandidates: boolean,
): string {
  const lines: string[] = [];

  if (request.source?.kind === "camera") {
    lines.push(
      "This image is a photograph of a screen, taken with a phone camera. Expect glare, skew, and a border around the screen itself; read through them.",
    );
  }

  const where: string[] = [];
  if (request.source?.app_name) where.push(`application: ${request.source.app_name}`);
  if (request.source?.window_title) where.push(`window: ${request.source.window_title}`);
  if (where.length > 0) lines.push(`Where this came from — ${where.join(", ")}.`);

  if (request.tap_point) {
    lines.push(
      `The person tapped at x=${request.tap_point.x.toFixed(3)}, y=${request.tap_point.y.toFixed(3)} (fractions of the image, from the top-left).`,
    );
  }

  if (hasCandidates) lines.push(CANDIDATES_RULE);

  if (request.question?.trim()) {
    lines.push(`Their question: ${request.question.trim()}`);
  } else if (request.tap_point) {
    lines.push("They did not type a question. Explain what they tapped and what it does.");
  } else {
    lines.push("They did not type a question. Explain what this screen is and what to do here.");
  }

  return lines.join("\n\n");
}

export function buildCandidateBlock(request: AnalyzeRequest): string | null {
  const candidates = request.source?.candidates;
  if (!candidates || candidates.length === 0) return null;

  const rows = candidates.slice(0, 500).map((candidate) => {
    const { x, y, w, h } = candidate.box;
    return `${candidate.id}\t${candidate.role}\t${candidate.label}\t${x.toFixed(4)},${y.toFixed(4)},${w.toFixed(4)},${h.toFixed(4)}`;
  });

  return `Screen elements measured by the device (id, role, label, then x,y,w,h as fractions of the image):\n${rows.join("\n")}`;
}
