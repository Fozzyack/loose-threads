(() => {
    const list = document.querySelector(".post-list");
    const toggle = document.querySelector(".timeline-toggle");
    if (!list || !toggle || list.children.length < 2) return;

    const items = Array.from(list.children);
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.classList.add("timeline-light");
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("focusable", "false");
    const bead = document.createElementNS(ns, "circle");
    bead.setAttribute("r", "2.5");
    const motion = document.createElementNS(ns, "animateMotion");
    motion.setAttribute("dur", "6s");
    motion.setAttribute("repeatCount", "indefinite");
    motion.setAttribute("calcMode", "paced");
    bead.append(motion);
    svg.append(bead);
    items[0].append(svg);
    toggle.hidden = false;

    function updatePath() {
        const bounds = list.getBoundingClientRect();
        svg.style.height = `${bounds.height}px`;
        const markers = items.map((item) => {
            const link = item.querySelector(".post-link");
            const rect = link.getBoundingClientRect();
            const marker = getComputedStyle(link, "::before");
            return {
                x: rect.left - bounds.left + parseFloat(marker.left) + parseFloat(marker.width) / 2,
                y: rect.top - bounds.top + parseFloat(marker.top) + parseFloat(marker.height) / 2,
            };
        });
        let path = `M${markers[0].x} ${markers[0].y}`;
        for (let i = 0; i < markers.length - 1; i++) {
            const start = markers[i];
            const end = markers[i + 1];
            if (i % 2 === 0) {
                path += ` L${end.x} ${end.y}`;
                continue;
            }
            const width = parseFloat(getComputedStyle(items[i], "::before").width);
            const point = (x, y) => `${start.x + (x - 12) * width / 24} ${start.y + y * (end.y - start.y) / 100}`;
            path += ` C${point(12, 16)} ${point(3, 20)} ${point(5, 32)}`;
            path += ` C${point(7, 44)} ${point(22, 42)} ${point(21, 52)}`;
            path += ` C${point(20, 64)} ${point(3, 61)} ${point(4, 50)}`;
            path += ` C${point(5, 39)} ${point(20, 47)} ${point(18, 65)}`;
            path += ` C${point(17, 80)} ${point(7, 83)} ${point(12, 100)}`;
        }
        motion.setAttribute("path", path);
    }

    let paused = false;
    const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
    function syncPlayback() {
        if (paused || reducedMotion.matches) svg.pauseAnimations();
        else svg.unpauseAnimations();
        toggle.textContent = paused ? "Play light" : "Pause light";
    }
    toggle.addEventListener("click", () => {
        paused = !paused;
        syncPlayback();
    });
    reducedMotion.addEventListener("change", syncPlayback);
    new ResizeObserver(updatePath).observe(list);
    updatePath();
    syncPlayback();
})();
