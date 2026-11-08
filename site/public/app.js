// The comparison slider and the demo loader.
for (const figure of document.querySelectorAll("[data-compare]")) {
  const frame = figure.querySelector(".compare-frame");
  const range = figure.querySelector(".compare-range");
  const update = () => frame.style.setProperty("--split", range.value + "%");
  range.addEventListener("input", update);
  update();
}

const loadButton = document.querySelector("[data-load-demo]");
const demoStage = document.querySelector("[data-demo-stage]");

loadButton?.addEventListener("click", () => {
  const frame = document.createElement("iframe");
  frame.src = "/demo/";
  frame.title = "godot-uxml web demo";
  frame.allow = "fullscreen; gamepad; clipboard-write";
  demoStage.append(frame);
  frame.focus();
});
