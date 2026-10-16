// Luma is an open-source project built by Design X Develop LLC.
// Copyright (c) 2026 Design X Develop LLC. MIT License.
//
// Minimal DOM morphing: patches the live tree toward freshly rendered markup so
// telemetry updates never steal focus, reset a caret, or move a slider being dragged.
// ponytail: index-based child matching (plus data-key); a keyed diff would only matter for huge lists.

export interface MorphOptions {
  /** Return true to keep this form control's current value (focused text, active slider draft). */
  protect(el: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement): boolean;
}

const UI_STATE_ATTRS = new Set(['open']); // <details>/<dialog> open state belongs to the user

export function morph(target: Element, html: string, options: MorphOptions): void {
  const template = document.createElement('template');
  template.innerHTML = html;
  patchChildren(target, template.content, options);
}

function patchChildren(live: Node, next: Node, options: MorphOptions): void {
  const liveKids = Array.from(live.childNodes);
  const nextKids = Array.from(next.childNodes);
  for (let i = 0; i < nextKids.length; i++) {
    const want = nextKids[i]!;
    const have = liveKids[i];
    if (!have) { live.appendChild(want.cloneNode(true)); continue; }
    if (!sameKind(have, want)) { live.replaceChild(want.cloneNode(true), have); continue; }
    if (have.nodeType === Node.TEXT_NODE || have.nodeType === Node.COMMENT_NODE) {
      if (have.nodeValue !== want.nodeValue) have.nodeValue = want.nodeValue;
      continue;
    }
    patchElement(have as Element, want as Element, options);
  }
  for (let i = liveKids.length - 1; i >= nextKids.length; i--) live.removeChild(liveKids[i]!);
}

function sameKind(a: Node, b: Node): boolean {
  if (a.nodeType !== b.nodeType) return false;
  if (a.nodeType !== Node.ELEMENT_NODE) return true;
  const ea = a as Element, eb = b as Element;
  return ea.tagName === eb.tagName && ea.getAttribute('data-key') === eb.getAttribute('data-key')
    && (ea.tagName !== 'INPUT' || ea.getAttribute('type') === eb.getAttribute('type'));
}

function patchElement(live: Element, next: Element, options: MorphOptions): void {
  for (const attr of Array.from(live.attributes)) {
    if (!next.hasAttribute(attr.name) && !UI_STATE_ATTRS.has(attr.name)) live.removeAttribute(attr.name);
  }
  for (const attr of Array.from(next.attributes)) {
    if (UI_STATE_ATTRS.has(attr.name)) continue;
    if (live.getAttribute(attr.name) !== attr.value) live.setAttribute(attr.name, attr.value);
  }
  if (live instanceof HTMLInputElement || live instanceof HTMLTextAreaElement || live instanceof HTMLSelectElement) {
    if (live instanceof HTMLSelectElement) patchChildren(live, next, options);
    if (!options.protect(live)) {
      const value = next.getAttribute('value') ?? (next instanceof HTMLTextAreaElement ? next.value : null);
      if (live instanceof HTMLInputElement && (live.type === 'checkbox' || live.type === 'radio')) {
        live.checked = next.hasAttribute('checked');
      } else if (live instanceof HTMLSelectElement) {
        const selected = (next as HTMLSelectElement).querySelector('option[selected]')?.getAttribute('value');
        if (selected != null && live.value !== selected) live.value = selected;
      } else if (value !== null && live.value !== value) {
        live.value = value;
      }
    }
    if (live instanceof HTMLTextAreaElement) return;
    return;
  }
  patchChildren(live, next, options);
}
