// Cross stitch embroidery shader.
// A pattern (one pixel per stitch, drawn on a 2D canvas) is rendered as thread on aida cloth:
// two twisted strands per cell, lit from the pointer, sewn in from top to bottom on first view.

const VERT = `
attribute vec2 aPos;
void main() { gl_Position = vec4(aPos, 0.0, 1.0); }
`;

const FRAG = `
precision highp float;
uniform sampler2D uPat;
uniform vec2 uGrid;
uniform vec2 uRes;
uniform float uCell;
uniform float uTime;
uniform float uSweep;
uniform vec2 uLight;
uniform vec3 uFabric;

float h21(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float vnoise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(h21(i), h21(i + vec2(1.0, 0.0)), f.x),
             mix(h21(i + vec2(0.0, 1.0)), h21(i + vec2(1.0, 1.0)), f.x), f.y);
}

vec4 stitchAt(vec2 c) {
  if (c.x < 0.0 || c.y < 0.0 || c.x >= uGrid.x || c.y >= uGrid.y) return vec4(0.0);
  return texture2D(uPat, (c + 0.5) / uGrid);
}

// How far along a leg has been sewn, 0 to 1. Leg 1 follows leg 0.
float grown(vec2 c, float leg) {
  float start = (c.y / uGrid.y) * uSweep + h21(c) * 0.45 + leg * 0.16;
  return clamp((uTime - start) / 0.2, 0.0, 1.0);
}

// Leg endpoints, jittered a little per cell so the work looks hand sewn.
void legEnds(vec2 c, float leg, out vec2 a, out vec2 b) {
  vec2 j = (vec2(h21(c + leg * 3.1), h21(c + 9.7 + leg)) - 0.5) * 0.05;
  if (leg < 0.5) { a = vec2(0.05, 0.95) + j; b = vec2(0.95, 0.05) - j; }
  else           { a = vec2(0.05, 0.05) + j.yx; b = vec2(0.95, 0.95) - j.yx; }
}

// Signed geometry of a strand: x = coverage, y = across (-1..1), z = along (0..1).
vec3 legShape(vec2 f, vec2 a, vec2 b, float grow, float aa) {
  vec2 ab = b - a;
  float len = length(ab);
  vec2 dir = ab / len;
  vec2 nr = vec2(-dir.y, dir.x);
  vec2 ap = f - a;
  float t = dot(ap, dir) / len;
  float s = dot(ap, nr);
  float tc = clamp(t, 0.0, 1.0);
  float w = 0.22 * (0.55 + 0.45 * sin(3.14159 * tc));
  float cov = 1.0 - smoothstep(w - aa, w + aa, abs(s));
  cov *= smoothstep(-0.03, 0.02, t) * (1.0 - smoothstep(0.98, 1.03, t));
  cov *= 1.0 - smoothstep(grow - 0.04, grow, t);
  return vec3(cov, clamp(s / w, -1.0, 1.0), t);
}

vec3 shadeThread(vec3 g, vec2 a, vec2 b, vec3 tcol, float seed, vec3 L) {
  vec2 dir = normalize(b - a);
  vec2 nr = vec2(-dir.y, dir.x);
  float u = g.y;
  vec3 N = normalize(vec3(nr * u * 0.95, sqrt(max(1.0 - u * u, 0.03))));
  float diff = max(dot(N, L), 0.0);
  float len = length(b - a);
  // six stranded floss: diagonal plies twisting along the strand
  float tw = sin((g.z * len * 8.0 - u * 1.1 + seed) * 6.2832);
  float fib = vnoise(vec2(g.z * len * 60.0 + seed * 17.0, u * 5.0));
  vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
  float spec = pow(max(dot(N, H), 0.0), 18.0) * 0.3 * (0.55 + 0.45 * tw);
  vec3 c = tcol * (0.5 + 0.62 * diff);
  c *= (0.84 + 0.16 * tw) * (0.9 + 0.14 * fib);
  c *= 0.62 + 0.38 * N.z;
  return c * 1.08 + spec * vec3(1.0, 0.96, 0.9);
}

float stitchCover(vec2 q, float aa) {
  vec2 c = floor(q), f = fract(q);
  if (stitchAt(c).a < 0.5) return 0.0;
  vec2 a, b, a2, b2;
  legEnds(c, 0.0, a, b);
  legEnds(c, 1.0, a2, b2);
  return max(legShape(f, a, b, grown(c, 0.0), aa).x, legShape(f, a2, b2, grown(c, 1.0), aa).x);
}

void main() {
  vec2 px = vec2(gl_FragCoord.x, uRes.y - gl_FragCoord.y);
  vec2 p = px / uCell;
  vec2 cell = floor(p);
  vec2 f = fract(p);
  float aa = 1.1 / uCell;

  vec3 L = normalize(vec3(clamp((uLight - px) / (uCell * 22.0), -1.4, 1.4), 1.1));

  // aida cloth: raised woven blocks with holes at the corners
  vec2 e = min(f, 1.0 - f);
  float block = smoothstep(0.0, 0.24, min(e.x, e.y));
  float hole = 1.0 - smoothstep(0.06, 0.15, length(e));
  float weave = 0.5 + 0.5 * sin(f.x * 18.85 + 1.0) * sin(f.y * 18.85);
  float n = vnoise(p * 0.3) * 0.6 + vnoise(p * 2.3) * 0.4;
  vec3 col = uFabric * (0.8 + 0.2 * block) * (0.93 + 0.09 * weave) * (0.9 + 0.16 * n);
  col *= 1.0 - 0.5 * hole;

  // thread casts a soft shadow away from the light
  vec2 sh = -L.xy * 0.12;
  col *= 1.0 - 0.42 * stitchCover(p - sh, aa * 3.0);

  vec4 pc = stitchAt(cell);
  if (pc.a > 0.5) {
    vec3 tcol = pc.rgb * (0.95 + 0.1 * h21(cell + 7.0));
    vec2 a, b, a2, b2;
    legEnds(cell, 0.0, a, b);
    legEnds(cell, 1.0, a2, b2);
    vec3 g1 = legShape(f, a, b, grown(cell, 0.0), aa);
    vec3 g2 = legShape(f, a2, b2, grown(cell, 1.0), aa);
    if (g1.x > 0.0) {
      vec3 c1 = shadeThread(g1, a, b, tcol, h21(cell) * 6.0, L);
      // the top leg shades the bottom one where they cross
      float over = legShape(f - sh * 0.5, a2, b2, grown(cell, 1.0), aa * 3.0).x;
      col = mix(col, c1 * (1.0 - 0.35 * over), g1.x);
    }
    if (g2.x > 0.0) col = mix(col, shadeThread(g2, a2, b2, tcol, h21(cell + 3.0) * 6.0, L), g2.x);
  }

  gl_FragColor = vec4(col, 1.0);
}
`;

const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;

export function embroider(canvas, { cell, fabric, build, sweep = 2.2, host = canvas }) {
  const gl = canvas.getContext('webgl', { antialias: false, alpha: false, preserveDrawingBuffer: true });
  if (!gl) { canvas.classList.add('no-gl'); return; }

  const sh = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src);
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
    return s;
  };
  const prog = gl.createProgram();
  gl.attachShader(prog, sh(gl.VERTEX_SHADER, VERT));
  gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FRAG));
  gl.linkProgram(prog);
  gl.useProgram(prog);

  gl.bindBuffer(gl.ARRAY_BUFFER, gl.createBuffer());
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(prog, 'aPos');
  gl.enableVertexAttribArray(loc);
  gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

  const u = name => gl.getUniformLocation(prog, name);
  const U = { grid: u('uGrid'), res: u('uRes'), cell: u('uCell'), time: u('uTime'), sweep: u('uSweep'), light: u('uLight'), fabric: u('uFabric') };
  gl.uniform3fv(U.fabric, fabric.map(v => v / 255));
  gl.uniform1f(U.sweep, sweep);
  gl.uniform1i(u('uPat'), 0);

  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  for (const [k, v] of [[gl.TEXTURE_MIN_FILTER, gl.NEAREST], [gl.TEXTURE_MAG_FILTER, gl.NEAREST], [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE], [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE]]) gl.texParameteri(gl.TEXTURE_2D, k, v);

  const pat = document.createElement('canvas');
  const pctx = pat.getContext('2d', { willReadFrequently: true });
  let dpr = 1, start = null, visible = false, raf = 0, laidOut = false;
  const elapsed = () => (reduceMotion ? 1e3 : start === null ? 0 : (performance.now() - start) / 1000);
  let light = [0, 0], lightSet = false;

  function layout() {
    const r = canvas.getBoundingClientRect();
    if (!r.width || !r.height) return;
    laidOut = true;
    dpr = Math.min(devicePixelRatio || 1, 2);
    const c = typeof cell === 'function' ? cell(r.width) : cell;
    const cols = Math.ceil(r.width / c), rows = Math.ceil(r.height / c);
    canvas.width = Math.round(r.width * dpr);
    canvas.height = Math.round(r.height * dpr);
    pat.width = cols; pat.height = rows;
    pctx.clearRect(0, 0, cols, rows);
    build(pctx, { cols, rows, cell: c, rect: r });
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, pat);
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.uniform2f(U.grid, cols, rows);
    gl.uniform2f(U.res, canvas.width, canvas.height);
    gl.uniform1f(U.cell, c * dpr);
    if (!lightSet) light = [canvas.width * 0.2, -canvas.height * 0.15];
    draw();
  }

  function draw() {
    gl.uniform1f(U.time, elapsed());
    gl.uniform2f(U.light, light[0], light[1]);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  function frame() {
    raf = 0;
    draw();
    if (visible && elapsed() < sweep + 1) raf = requestAnimationFrame(frame);
  }
  const kick = () => { if (!raf) raf = requestAnimationFrame(frame); };

  new IntersectionObserver(([e]) => {
    visible = e.isIntersecting;
    if (!visible) return;
    if (!laidOut) layout();
    if (start === null) {
      start = performance.now();
      // paint the finished piece even if animation frames were throttled
      setTimeout(draw, (sweep + 1.2) * 1000);
    }
    kick();
  }).observe(canvas);

  new ResizeObserver(layout).observe(canvas);

  host.addEventListener('pointermove', e => {
    const r = canvas.getBoundingClientRect();
    light = [(e.clientX - r.left) * dpr, (e.clientY - r.top) * dpr - 160 * dpr];
    lightSet = true;
    if (visible) kick();
  });

  return { relayout: layout };
}

// Pixel helpers for building patterns
export function hex(h) {
  const n = parseInt(h.slice(1), 16);
  return [n >> 16, (n >> 8) & 255, n & 255];
}

export function plot(ctx, x, y, color) {
  ctx.fillStyle = color;
  ctx.fillRect(x, y, 1, 1);
}

const GLYPHS = {
  '0': ['01110', '10001', '10011', '10101', '11001', '10001', '01110'],
  '1': ['00100', '01100', '00100', '00100', '00100', '00100', '01110'],
  '2': ['01110', '10001', '00001', '00010', '00100', '01000', '11111'],
  '3': ['11110', '00001', '00001', '01110', '00001', '00001', '11110'],
  '4': ['00010', '00110', '01010', '10010', '11111', '00010', '00010'],
  '5': ['11111', '10000', '11110', '00001', '00001', '10001', '01110'],
  '6': ['00110', '01000', '10000', '11110', '10001', '10001', '01110'],
  '7': ['11111', '00001', '00010', '00100', '01000', '01000', '01000'],
  '8': ['01110', '10001', '10001', '01110', '10001', '10001', '01110'],
  '9': ['01110', '10001', '10001', '01111', '00001', '00010', '01100'],
};

// Draws text in a 5x7 stitch font; returns its width in cells.
export function stitchText(ctx, text, x, y, color) {
  [...text].forEach((ch, i) => {
    (GLYPHS[ch] || []).forEach((row, r) => [...row].forEach((bit, c) => {
      if (bit === '1') plot(ctx, x + i * 6 + c, y + r, color);
    }));
  });
  return text.length * 6 - 1;
}

export const textWidth = text => text.length * 6 - 1;
