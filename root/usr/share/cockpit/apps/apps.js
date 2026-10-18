"use strict";

// One section per app, with a tile per page inside it. The section heading
// links to the app's home.
// path: where the Cockpit tunnel routes the page on this hostname.
// port: where the app listens on the tailnet.
const SECTIONS = [
    {
        name: "Grafana", icon: "grafana.svg", path: "/grafana/", port: 3000,
        pages: [
            { name: "Media", icon: "media.svg", path: "/grafana/d/media" },
        ],
    },
];

// The tunnel serves Cockpit on the default HTTPS port. Direct access always
// names port 9090.
function appUrl(path, port) {
    const loc = window.location;
    if (loc.port === "")
        return `${loc.origin}${path}`;
    return `http://${loc.hostname}:${port}${path}`;
}

function appLink(name, icon, url) {
    const link = document.createElement("a");
    link.href = url;
    // Cockpit pages run in an iframe.
    link.target = "_blank";
    link.rel = "noopener";

    const img = document.createElement("img");
    img.src = icon;
    img.alt = "";

    const label = document.createElement("span");
    label.textContent = name;

    link.append(img, label);
    return link;
}

// Same logic as Cockpit's own pages, which follow the shell's style setting.
function applyTheme(style) {
    style = style || localStorage.getItem("shell:style") || "auto";
    const dark = style === "dark" ||
        (style === "auto" && window.matchMedia("(prefers-color-scheme: dark)").matches);
    document.documentElement.classList.toggle("dark", dark);
}

window.addEventListener("storage", event => {
    if (event.key === "shell:style")
        applyTheme();
});
window.addEventListener("cockpit-style", event => applyTheme(event.detail?.style));
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => applyTheme());
applyTheme();

document.addEventListener("DOMContentLoaded", () => {
    const main = document.getElementById("apps");
    for (const section of SECTIONS) {
        const heading = document.createElement("h2");
        heading.append(appLink(section.name, section.icon, appUrl(section.path, section.port)));

        const list = document.createElement("ul");
        list.className = "grid";
        for (const page of section.pages) {
            const item = document.createElement("li");
            item.append(appLink(page.name, page.icon, appUrl(page.path, section.port)));
            list.append(item);
        }

        const element = document.createElement("section");
        element.append(heading, list);
        main.append(element);
    }
});
