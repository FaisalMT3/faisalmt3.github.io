// Hero ring: every piece of work as a curved screen on a 3D carousel. index.html owns the scroll (state.p runs 0 to 1
// while the hero is pinned); this file only draws. Neon rails, a light cone and dust carry the bloom.
import * as THREE from "three";
import { EffectComposer } from "three/addons/postprocessing/EffectComposer.js";
import { RenderPass } from "three/addons/postprocessing/RenderPass.js";
import { UnrealBloomPass } from "three/addons/postprocessing/UnrealBloomPass.js";
import { OutputPass } from "three/addons/postprocessing/OutputPass.js";

export default function ring({ canvas, hero, state, WORK, reduced, onFront }) {
  const phone = innerWidth < 768;
  const N = WORK.length, H = 1.34, STEP = Math.PI * 2 / N, ARC = STEP * .91;
  const R = 2.1 / ARC;                                   // radius that keeps every screen 16:10
  const FLOOR = -H / 2 - .1;

  const renderer = new THREE.WebGLRenderer({ canvas, antialias: !phone, powerPreference: "high-performance" });
  renderer.setPixelRatio(Math.min(devicePixelRatio, phone ? 1.5 : 1.75));
  const scene = new THREE.Scene();
  scene.fog = new THREE.Fog(0x000000, 1, 2);
  const cam = new THREE.PerspectiveCamera(32, 1, .1, 80);
  const rig = new THREE.Group(), spin = new THREE.Group(), mirror = new THREE.Group(), mspin = new THREE.Group();
  mirror.scale.y = -1; mirror.position.y = 2 * FLOOR; mirror.add(mspin);
  rig.add(spin, mirror); scene.add(rig);

  // Screens: a slice of a cylinder each, so they curve with the ring. The mirrored copy fades toward the floor.
  const geo = new THREE.CylinderGeometry(R, R, H, 28, 1, true, -ARC / 2, ARC);
  const fade = document.createElement("canvas"); fade.width = 4; fade.height = 64;
  const fg = fade.getContext("2d"), grad = fg.createLinearGradient(0, 0, 0, 64);
  grad.addColorStop(0, "#000"); grad.addColorStop(.55, "#000"); grad.addColorStop(1, "#9a9a9a");
  fg.fillStyle = grad; fg.fillRect(0, 0, 4, 64);
  const fadeTex = new THREE.CanvasTexture(fade);
  const back = new THREE.MeshBasicMaterial({ color: 0x07090f, side: THREE.BackSide });
  const manager = new THREE.LoadingManager(() => canvas.classList.add("in"));
  const loader = new THREE.TextureLoader(manager), mats = [];
  WORK.forEach((w, i) => {
    const map = loader.load(w.img); map.colorSpace = THREE.SRGBColorSpace; map.anisotropy = 8;
    const mat = new THREE.MeshBasicMaterial({ map });
    const refl = new THREE.MeshBasicMaterial({ map, alphaMap: fadeTex, transparent: true, opacity: .3, side: THREE.DoubleSide, depthWrite: false });
    const a = new THREE.Mesh(geo, mat), b = new THREE.Mesh(geo, back), c = new THREE.Mesh(geo, refl);
    a.rotation.y = b.rotation.y = c.rotation.y = i * STEP;
    spin.add(a, b); mspin.add(c); mats.push(mat);
  });

  // Neon rails (HDR colour, so only these bloom), light cone, floor pool, dust
  const railMat = new THREE.MeshBasicMaterial({ color: new THREE.Color(.4, 1, 2.6) });
  const railGeo = new THREE.TorusGeometry(R + .01, .011, 8, 260);
  [H / 2 + .07, -H / 2 - .07].forEach(y => { const m = new THREE.Mesh(railGeo, railMat); m.rotation.x = Math.PI / 2; m.position.y = y; spin.add(m); });
  const glow = (frag, g) => new THREE.Mesh(g, new THREE.ShaderMaterial({ transparent: true, depthWrite: false, blending: THREE.AdditiveBlending, side: THREE.DoubleSide,
    vertexShader: "varying vec3 vN; varying vec2 vUv; void main(){ vUv = uv; vN = normalize(normalMatrix * normal); gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.); }",
    fragmentShader: "varying vec3 vN; varying vec2 vUv; void main(){ " + frag + " }" }));
  const cone = glow("float f = pow(abs(vN.z), 2.2); float h = smoothstep(0., .25, vUv.y) * pow(vUv.y, 1.5); gl_FragColor = vec4(vec3(.32, .55, 1.) * f * h * .3, 1.);",
    new THREE.CylinderGeometry(.2, R * .78, 8, 48, 1, true));
  cone.position.y = FLOOR + 4;
  const pool = glow("float d = length(vUv - .5) * 2.; gl_FragColor = vec4(vec3(.16, .32, .9) * pow(max(1. - d, 0.), 2.4) * .8, 1.);", new THREE.PlaneGeometry(R * 3.6, R * 3.6));
  pool.rotation.x = -Math.PI / 2; pool.position.y = FLOOR - .01;
  const DN = phone ? 700 : 1500, dp = new Float32Array(DN * 3);
  for (let i = 0; i < DN; i++) { const a = Math.random() * 6.283, r = Math.sqrt(Math.random()) * R * 1.5; dp.set([Math.cos(a) * r, FLOOR + Math.random() * 5, Math.sin(a) * r], i * 3); }
  const dustGeo = new THREE.BufferGeometry(); dustGeo.setAttribute("position", new THREE.BufferAttribute(dp, 3));
  const dust = new THREE.Points(dustGeo, new THREE.PointsMaterial({ color: new THREE.Color(.7, 1.1, 2.2), size: .028, transparent: true, opacity: .75, blending: THREE.AdditiveBlending, depthWrite: false }));
  rig.add(cone, pool, dust);

  const composer = new EffectComposer(renderer);
  composer.addPass(new RenderPass(scene, cam));
  composer.addPass(new UnrealBloomPass(new THREE.Vector2(1, 1), .5, .5, 1));
  composer.addPass(new OutputPass());
  const size = () => { const w = hero.clientWidth, h = hero.clientHeight; renderer.setSize(w, h, false); composer.setSize(w, h); cam.aspect = w / h; cam.updateProjectionMatrix(); };
  size(); addEventListener("resize", size);

  let mx = 0, my = 0, tx = 0, ty = 0, seen = true, running = false;
  addEventListener("pointermove", e => { tx = e.clientX / innerWidth - .5; ty = e.clientY / innerHeight - .5; });
  const ss = (a, b, x) => { x = Math.min(Math.max((x - a) / (b - a), 0), 1); return x * x * (3 - 2 * x); };
  const look = new THREE.Vector3();
  const draw = now => {
    running = false;
    const t = now / 1000, p = state.p, go = ss(0, .16, p), wide = cam.aspect > 1.2, far = Math.max(1, .67 / cam.aspect);
    const idx = Math.min(Math.max((p - .14) / .82, 0), 1) * (N - 1);
    spin.rotation.y = mspin.rotation.y = -idx * STEP + (reduced ? 0 : t * .07 * (1 - go));
    // Intro: seen from above, beside the headline (under it on a phone). Gallery: level, close, one screen filling the frame.
    const base = R + 8.6 - 3.9 * go, extra = base * (far - 1);
    cam.position.set(0, 2.5 - 2.3 * go, base + extra);
    scene.fog.near = R + 2.1 + extra; scene.fog.far = R + 12.1 + extra;
    look.set(0, (wide ? -.25 : 2.6) * (1 - go) - .68 * go * far, 0); cam.lookAt(look);
    rig.position.x = wide ? -.8 * R * (1 - go) : 0;
    mx += (tx - mx) * .05; my += (ty - my) * .05;
    rig.rotation.y = mx * .16; rig.rotation.x = my * .05;
    const turn = spin.rotation.y + rig.rotation.y;      // the screen facing the camera is lit, the others fall back
    mats.forEach((m, i) => { const a = Math.atan2(Math.sin(i * STEP + turn), Math.cos(i * STEP + turn)); m.color.setScalar(.34 + .66 * Math.exp(-a * a * (2 + 9 * go))); });
    dust.rotation.y = t * .03; dust.position.y = Math.sin(t * .2) * .15;
    railMat.color.setRGB(.4, 1, 2.6).multiplyScalar(.85 + .15 * Math.sin(t * 1.6));
    onFront(Math.round(idx), p);
    composer.render();
    kick();
  };
  const kick = () => { if (!running && seen && !document.hidden && !reduced) { running = true; requestAnimationFrame(draw); } };
  new IntersectionObserver(([e]) => { seen = e.isIntersecting; kick(); }).observe(hero);   // no drawing once the hero is off screen
  document.addEventListener("visibilitychange", kick);
  running = true; requestAnimationFrame(draw);
  if (reduced) manager.onLoad = () => { canvas.classList.add("in"); requestAnimationFrame(draw); };   // still frame once the screens are in
}
