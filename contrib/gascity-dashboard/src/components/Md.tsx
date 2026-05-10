import ReactMarkdown from 'react-markdown';
import type { CSSProperties } from 'react';

// One place that decides how we render untrusted markdown text in the UI.
// Used for bead descriptions, mail bodies, comments, review/impl.md, etc.
//
// NOTE: we don't need a sanitizer because the content comes from our own
// backend (Claude-written docs, no user-supplied HTML). If we ever expose
// this to external input we should pipe it through rehype-sanitize.

export default function Md({ children, style }: { children: string; style?: CSSProperties }) {
  return (
    <div className="markdown" style={style}>
      <ReactMarkdown>{children || ''}</ReactMarkdown>
    </div>
  );
}
