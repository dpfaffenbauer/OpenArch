// openarch.app behaves like an OpenArch window: the part of the page you are
// in is a space with its own theme and tabs, ⌘K opens a command bar over the
// page, the sidebar hides and floats back, and the theme editor and the icon
// picker work on the page itself. Without this script the page still reads
// from top to bottom, with every tab listed in the sidebar.
(() => {
  const root = document.documentElement;
  const $ = (selector, parent = document) => parent.querySelector(selector);
  const $$ = (selector, parent = document) => [...parent.querySelectorAll(selector)];
  const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const darkMode = matchMedia('(prefers-color-scheme: dark)');
  const moreContrast = matchMedia('(prefers-contrast: more)');
  const smallScreen = matchMedia('(max-width: 56em)');

  // Days until Arc stops.
  const days = Math.ceil((new Date('2026-12-22T00:00:00') - Date.now()) / 86400000);
  if (days > 0) {
    for (const element of $$('[data-countdown]')) {
      element.textContent = element.dataset.countdown.replace('{n}', days).replace('{days}', days === 1 ? 'day' : 'days');
      element.hidden = false;
    }
  }

  // ---- Colors -------------------------------------------------------------

  const hexToRgb = (hex) => [1, 3, 5].map((at) => parseInt(hex.slice(at, at + 2), 16) / 255);
  const rgbToHex = (rgb) => '#' + rgb.map((value) => Math.round(Math.min(1, Math.max(0, value)) * 255).toString(16).padStart(2, '0')).join('');
  const mix = (above, below, alpha) => above.map((value, index) => value * alpha + below[index] * (1 - alpha));

  // WCAG luminance and contrast.
  const luminance = (rgb) => {
    const [r, g, b] = rgb.map((value) => (value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4));
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const contrast = (one, two) => {
    const [light, dark] = [luminance(one), luminance(two)].sort((a, b) => b - a);
    return (light + 0.05) / (dark + 0.05);
  };

  const hslToRgb = (hue, saturation, lightness) => {
    const chroma = (1 - Math.abs(2 * lightness - 1)) * saturation;
    const h = (((hue % 360) + 360) % 360) / 60;
    const x = chroma * (1 - Math.abs((h % 2) - 1));
    const [r, g, b] = [[chroma, x, 0], [x, chroma, 0], [0, chroma, x], [0, x, chroma], [x, 0, chroma], [chroma, 0, x]][Math.floor(h) % 6];
    const m = lightness - chroma / 2;
    return [r + m, g + m, b + m];
  };

  // The theme editor's disc, as in the app: the hue by the angle (0 at the
  // right, clockwise), the lightness from 0.16 in the middle to 0.9 at the edge.
  const discColor = (angle, radius) => rgbToHex(hslToRgb(angle, 0.9, 0.16 + 0.74 * Math.min(1, Math.max(0, radius))));
  const discPosition = (hex) => {
    const [r, g, b] = hexToRgb(hex);
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const delta = max - min;
    let hue = 0;
    if (delta > 0) {
      if (max === r) hue = 60 * (((g - b) / delta) % 6);
      else if (max === g) hue = 60 * ((b - r) / delta + 2);
      else hue = 60 * ((r - g) / delta + 4);
    }
    if (hue < 0) hue += 360;
    return { angle: hue, radius: Math.min(1, Math.max(0, ((max + min) / 2 - 0.16) / 0.74)) };
  };

  // ---- Spaces and their themes -----------------------------------------------

  // One to three colors, intensity and grain, as a space keeps them.
  const presets = {
    move: { colors: ['#55b860', '#2bb3a3', '#c6d94e'], intensity: 0.81, grain: 0.35 },
    browse: { colors: ['#3e7be6', '#7b6cf6', '#3fc6e0'], intensity: 0.81, grain: 0.35 },
    claude: { colors: ['#f08a3c', '#e5566a', '#f2d46c'], intensity: 0.81, grain: 0.35 },
    everywhere: { colors: ['#9e749b', '#e59eba', '#7eb6d5'], intensity: 0.81, grain: 0.35 },
  };
  // Themes edited on this page, by space.
  const edited = {};
  let space = root.dataset.space || 'move';
  const themeOf = (name) => edited[name] || presets[name];
  const themeColorMeta = $('meta[name="theme-color"]');

  // Sets the ground's colors. They lie at 0.2 + 0.55 × intensity over white
  // or black; where the sidebar's text would no longer read on them, they are
  // washed out until it does, as the app does it.
  function applyTheme() {
    const theme = themeOf(space);
    const [one, two = one, three = two] = theme.colors;
    const under = hexToRgb(darkMode.matches ? '#070908' : '#ffffff');
    const text = hexToRgb(darkMode.matches ? '#f3f5f1' : '#141814');
    // The colors where text lies: the first two, and the third as far as it
    // has come in at the bottom of the window.
    const samples = [hexToRgb(one), hexToRgb(two), mix(hexToRgb(three), hexToRgb(two), 0.65)];
    let wash = Math.min(0.2 + 0.55 * theme.intensity, moreContrast.matches ? 0.35 : 1);
    while (wash > 0.1 && samples.some((color) => contrast(mix(color, under, wash), text) < 5.2)) wash -= 0.02;

    root.style.setProperty('--c1', one);
    root.style.setProperty('--c2', two);
    root.style.setProperty('--c3', three);
    root.style.setProperty('--wash', wash.toFixed(3));
    root.style.setProperty('--grain', theme.grain);
    themeColorMeta?.setAttribute('content', rgbToHex(mix(hexToRgb(one), under, wash)));
  }

  const sections = $$('.page[id]');
  const tabLinks = new Map($$('.tabs a').map((link) => [link.hash.slice(1), link]));
  const spaceLinks = $$('[data-space-link]');
  let sectionInFront = null;

  // The section at the reading line decides which tab is marked, and its
  // space decides the theme and which tabs the sidebar lists.
  function findSectionInFront() {
    const line = innerHeight * 0.38;
    let front = sections[0];
    let frontTop = -Infinity;
    for (const section of sections) {
      const top = section.getBoundingClientRect().top;
      // Of two pages side by side, the first one counts.
      if (top <= line && top > frontTop + 1) {
        front = section;
        frontTop = top;
      }
    }
    if (innerHeight + scrollY >= document.documentElement.scrollHeight - 4) front = sections.at(-1);
    return front;
  }

  function updateSpace() {
    const front = findSectionInFront();
    if (front === sectionInFront) return;
    sectionInFront = front;
    for (const [id, link] of tabLinks) {
      if (id === front.id) link.setAttribute('aria-current', 'true');
      else link.removeAttribute('aria-current');
    }

    const name = front.closest('.space').dataset.space;
    if (name === space && root.style.getPropertyValue('--c1')) return;
    space = name;
    root.dataset.space = name;
    for (const link of spaceLinks) {
      if (link.dataset.spaceLink === name) link.setAttribute('aria-current', 'true');
      else link.removeAttribute('aria-current');
    }
    applyTheme();
    syncEditor();
  }

  let spyQueued = false;
  const queueSpy = () => {
    if (spyQueued) return;
    spyQueued = true;
    requestAnimationFrame(() => {
      spyQueued = false;
      updateSpace();
    });
  };
  addEventListener('scroll', queueSpy, { passive: true });
  addEventListener('resize', queueSpy);
  darkMode.addEventListener('change', applyTheme);
  moreContrast.addEventListener('change', applyTheme);

  const scrollTo = (element, block = 'start') => element.scrollIntoView({ behavior: reduceMotion.matches ? 'auto' : 'smooth', block });

  // ⌃1 to ⌃4 change spaces, as ⌃1 to ⌃9 do in the app.
  const onMac = /Mac|iPhone|iPad/.test(navigator.platform);
  addEventListener('keydown', (event) => {
    if (!onMac || !event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return;
    const link = spaceLinks[Number(event.key) - 1];
    if (!link) return;
    event.preventDefault();
    scrollTo($(link.hash));
  });

  // ---- The sidebar: hidden, floating, over the page, left or right ----------

  const sidebar = $('#sidebar');
  const toggles = $$('[data-sidebar-toggle]');

  function showSidebarState() {
    const open = smallScreen.matches ? root.dataset.drawer === 'open' : root.dataset.sidebar !== 'hidden';
    for (const toggle of toggles) {
      toggle.setAttribute('aria-expanded', open);
      const label = $('.sr-only', toggle);
      if (label) label.textContent = open ? 'Hide the sidebar' : 'Show the sidebar';
    }
    $('.scrim').hidden = !(smallScreen.matches && open);
  }

  function toggleSidebar(from) {
    if (smallScreen.matches) {
      const open = root.dataset.drawer !== 'open';
      if (open) root.dataset.drawer = 'open';
      else delete root.dataset.drawer;
      showSidebarState();
      if (open) $('.brand', sidebar).focus({ preventScroll: true });
      else (from instanceof HTMLElement ? from : $('.phone-bar [data-sidebar-toggle]')).focus({ preventScroll: true });
    } else {
      if (root.dataset.sidebar === 'hidden') delete root.dataset.sidebar;
      else root.dataset.sidebar = 'hidden';
      showSidebarState();
      // The button under the pointer went with the sidebar: move to its twin.
      if (document.activeElement?.matches?.('[data-sidebar-toggle]')) {
        (root.dataset.sidebar === 'hidden' ? $('.sb-show') : $('.sb-top [data-sidebar-toggle]')).focus({ preventScroll: true });
      }
    }
    queueSpy();
  }

  const closeDrawer = () => {
    if (root.dataset.drawer !== 'open') return;
    delete root.dataset.drawer;
    showSidebarState();
  };

  for (const toggle of toggles) toggle.addEventListener('click', () => toggleSidebar(toggle));
  $('.scrim').addEventListener('click', closeDrawer);
  sidebar.addEventListener('click', (event) => event.target.closest('a') && closeDrawer());
  smallScreen.addEventListener('change', () => {
    closeDrawer();
    showSidebarState();
  });
  addEventListener('keydown', (event) => {
    if (event.key !== 'Escape' || root.dataset.drawer !== 'open') return;
    closeDrawer();
    $('.phone-bar [data-sidebar-toggle]').focus({ preventScroll: true });
  });

  const sideButtons = $$('[data-side]');
  function setSide(side) {
    if (side === 'right') root.dataset.side = 'right';
    else delete root.dataset.side;
    for (const button of sideButtons) button.setAttribute('aria-pressed', button.dataset.side === side);
  }
  for (const button of sideButtons) button.addEventListener('click', () => setSide(button.dataset.side));

  // ---- The arches --------------------------------------------------------------

  const tunnel = $('[data-warp]');
  const door = $('.arch.door', tunnel);
  // The door is the last arch to arrive, at the page's start and after a
  // flight. From then on the arches stand (style.css: .risen).
  door.addEventListener('animationend', () => {
    tunnel.classList.remove('warp');
    tunnel.classList.add('risen');
  });

  // A click flies through the arches, as a click on the logo does in the
  // app's About window.
  function warp() {
    if (reduceMotion.matches) return;
    tunnel.classList.remove('warp');
    void tunnel.offsetWidth;
    tunnel.classList.add('warp');
  }
  tunnel.addEventListener('click', warp);

  // The far arches follow the pointer a little.
  const hero = tunnel.closest('.page');
  hero.addEventListener('pointermove', (event) => {
    if (reduceMotion.matches || event.pointerType !== 'mouse') return;
    const box = hero.getBoundingClientRect();
    tunnel.style.setProperty('--px', (((event.clientX - box.left) / box.width) * 2 - 1).toFixed(3));
  });
  hero.addEventListener('pointerleave', () => tunnel.style.setProperty('--px', 0));

  // ---- The theme editor ---------------------------------------------------------

  const disc = $('#disc');
  const lessButton = $('#theme-less');
  const moreButton = $('#theme-more');
  const intensityInput = $('#theme-intensity');
  const grainInput = $('#theme-grain');
  // Arc's nine swatches.
  const swatches = ['#f0eae5', '#e59eba', '#9e749b', '#e1676f', '#ef8c63', '#f2d46c', '#73e49b', '#7eb6d5', '#656786'];
  let selectedHandle = 0;

  // The disc itself, drawn once.
  {
    const canvas = $('canvas', disc);
    const context = canvas.getContext('2d');
    const size = canvas.width;
    const image = context.createImageData(size, size);
    for (let y = 0; y < size; y++) {
      for (let x = 0; x < size; x++) {
        const dx = (x + 0.5) / size * 2 - 1;
        const dy = (y + 0.5) / size * 2 - 1;
        const radius = Math.hypot(dx, dy);
        if (radius > 1) continue;
        const [r, g, b] = hslToRgb(Math.atan2(dy, dx) * 180 / Math.PI, 0.9, 0.16 + 0.74 * radius);
        image.data.set([r * 255, g * 255, b * 255, 255], (y * size + x) * 4);
      }
    }
    context.putImageData(image, 0, 0);
  }

  // The theme being edited: the space's own copy, made at the first change.
  const editing = () => (edited[space] ??= structuredClone(presets[space]));

  function themeChanged() {
    applyTheme();
    syncEditor();
  }

  // Places a handle for each color and sets the controls to the theme.
  function syncEditor() {
    const theme = themeOf(space);
    selectedHandle = Math.min(selectedHandle, theme.colors.length - 1);
    const handles = $$('.handle', disc);
    theme.colors.forEach((color, index) => {
      const handle = handles[index] || disc.appendChild(makeHandle(index));
      const { angle, radius } = discPosition(color);
      handle.style.left = `${50 + Math.cos(angle * Math.PI / 180) * radius * 50}%`;
      handle.style.top = `${50 + Math.sin(angle * Math.PI / 180) * radius * 50}%`;
      handle.style.background = color;
      handle.setAttribute('aria-label', `Color ${index + 1}: ${color}. The arrow keys change it.`);
    });
    for (const extra of handles.slice(theme.colors.length)) extra.remove();
    lessButton.disabled = theme.colors.length <= 1;
    moreButton.disabled = theme.colors.length >= 3;
    intensityInput.value = theme.intensity;
    grainInput.value = theme.grain;
    $('#theme-reset').hidden = !edited[space];
  }

  // A handle moves to an angle and a distance from the middle. The first
  // one turns the others with it; the others move alone.
  function moveHandle(index, angle, radius) {
    const theme = editing();
    if (index === 0) {
      const turned = angle - discPosition(theme.colors[0]).angle;
      theme.colors = theme.colors.map((color, other) => {
        if (other === 0) return discColor(angle, radius);
        const place = discPosition(color);
        return discColor(place.angle + turned, place.radius);
      });
    } else {
      theme.colors[index] = discColor(angle, radius);
    }
    themeChanged();
  }

  function makeHandle(index) {
    const handle = document.createElement('button');
    handle.type = 'button';
    handle.className = 'handle';
    const drag = (event) => {
      const box = disc.getBoundingClientRect();
      const dx = (event.clientX - box.left) / box.width * 2 - 1;
      const dy = (event.clientY - box.top) / box.height * 2 - 1;
      moveHandle(index, Math.atan2(dy, dx) * 180 / Math.PI, Math.min(1, Math.hypot(dx, dy)));
    };
    handle.addEventListener('pointerdown', (event) => {
      selectedHandle = index;
      handle.setPointerCapture(event.pointerId);
      root.classList.add('theming');
      handle.addEventListener('pointermove', drag);
    });
    const release = () => {
      handle.removeEventListener('pointermove', drag);
      root.classList.remove('theming');
    };
    handle.addEventListener('pointerup', release);
    handle.addEventListener('pointercancel', release);
    handle.addEventListener('focus', () => (selectedHandle = index));
    handle.addEventListener('keydown', (event) => {
      const step = { ArrowRight: [6, 0], ArrowLeft: [-6, 0], ArrowUp: [0, 0.05], ArrowDown: [0, -0.05] }[event.key];
      if (!step) return;
      event.preventDefault();
      const place = discPosition(themeOf(space).colors[index]);
      moveHandle(index, place.angle + step[0], Math.min(1, Math.max(0, place.radius + step[1])));
    });
    return handle;
  }

  lessButton.addEventListener('click', () => {
    editing().colors.pop();
    themeChanged();
  });
  // A second color starts opposite the first, a third beside it.
  moreButton.addEventListener('click', () => {
    const theme = editing();
    const first = discPosition(theme.colors[0]);
    theme.colors.push(discColor(first.angle + (theme.colors.length === 1 ? 180 : 210), first.radius));
    themeChanged();
  });
  intensityInput.addEventListener('input', () => {
    editing().intensity = Number(intensityInput.value);
    themeChanged();
  });
  grainInput.addEventListener('input', () => {
    editing().grain = Number(grainInput.value);
    themeChanged();
  });
  $('#theme-reset').addEventListener('click', () => {
    delete edited[space];
    themeChanged();
  });
  for (const color of swatches) {
    const button = document.createElement('button');
    button.type = 'button';
    button.style.background = color;
    button.setAttribute('aria-label', `Set the selected color to ${color}`);
    button.addEventListener('click', () => {
      editing().colors[selectedHandle] = color;
      themeChanged();
    });
    $('.swatches').append(button);
  }

  // ---- The app icons ------------------------------------------------------------

  const iconButtons = $$('.icon-grid button');
  const favicon = $('link[rel="icon"]');
  for (const button of iconButtons) {
    button.addEventListener('click', () => {
      for (const other of iconButtons) other.setAttribute('aria-pressed', other === button);
      const drawing = $('svg', button).innerHTML;
      for (const icon of $$('[data-app-icon]')) icon.innerHTML = `<svg viewBox="0 0 64 64" aria-hidden="true">${drawing}</svg>`;
      favicon.type = 'image/svg+xml';
      favicon.href = 'data:image/svg+xml,' + encodeURIComponent(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">${drawing}</svg>`);
    });
  }

  // ---- Copy the Claude Code command ---------------------------------------------

  async function copyCommand(button) {
    const text = $('#mcp-command').textContent;
    const status = $('#copy-status');
    try {
      await navigator.clipboard.writeText(text);
      if (button) button.textContent = 'Copied';
      status.textContent = 'Copied';
    } catch {
      if (button) button.textContent = 'Select and copy';
      status.textContent = 'Copying failed. Select the command and copy it.';
    }
    setTimeout(() => {
      if (button) button.textContent = 'Copy';
      status.textContent = '';
    }, 2500);
  }
  for (const button of $$('[data-copy]')) button.addEventListener('click', () => copyCommand(button));

  // ---- The command bar ----------------------------------------------------------

  const bar = $('#bar');
  const barInput = $('#bar-input');
  const barList = $('#bar-list');
  const text = (element) => element.textContent.replace(/\s+/g, ' ').trim();

  // Goes to a place on the page; a single feature or question lights up.
  function go(target, highlight) {
    const element = typeof target === 'string' ? $(target) : target;
    scrollTo(element, highlight ? 'center' : 'start');
    if (!highlight) return;
    element.classList.remove('found');
    void element.offsetWidth;
    element.classList.add('found');
    element.addEventListener('animationend', () => element.classList.remove('found'), { once: true });
  }

  const download = $('.fav-download').href;
  const spaceNames = Object.fromEntries($$('.space-list').map((list) => [list.dataset.space, text($('.space-name', list))]));

  // What the bar opens with, and finds first: the commands.
  const commands = [
    { title: 'Download for Mac', sub: 'The newest Stable version', hint: 'Download', icon: 'i-download', words: 'install get zip', run: () => (location.href = download) },
    ...spaceLinks.map((link, index) => ({
      title: `Go to ${spaceNames[link.dataset.spaceLink]}`, sub: 'Space', hint: `⌃${index + 1}`, icon: $('use', link).getAttribute('href').slice(1),
      words: 'switch space theme', run: () => go(link.hash),
    })),
    { title: 'Hide or show the sidebar', sub: 'Hidden, it floats back from the window’s edge', hint: '⌘S in OpenArch', icon: 'i-sidebar', words: 'toggle collapse hover', wide: true, run: () => toggleSidebar() },
    { title: 'Move the sidebar to the other side', sub: 'Left or right', icon: 'i-columns', words: 'right left position', wide: true, run: () => setSide(root.dataset.side === 'right' ? 'left' : 'right') },
    { title: 'Fly through the arches', sub: 'As a click on the logo does in About OpenArch', icon: 'i-arch', words: 'warp tunnel about', run: () => { go('#top'); setTimeout(warp, 350); } },
    { title: 'Copy the Claude Code command', sub: 'claude mcp add openarch …', icon: 'i-terminal', words: 'mcp devtools ai control', run: () => copyCommand() },
    { title: 'Read the documentation', sub: 'docs.openarch.app', icon: 'i-book', words: 'docs help manual', run: () => (location.href = 'https://docs.openarch.app/') },
    { title: 'Source on GitHub', sub: 'github.com/dpfaffenbauer/OpenArch', icon: 'i-code', words: 'code repository open source mit', run: () => (location.href = 'https://github.com/dpfaffenbauer/OpenArch') },
    { title: 'OpenArch for iPhone and iPad', sub: 'On the App Store', icon: 'i-phone', words: 'ios mobile', run: () => (location.href = $('#iphone .button').href) },
  ];

  // Everything else on the page: its sections, each little thing, what the
  // agents do, and the questions.
  const places = [
    ...$$('.space-list').flatMap((list) => $$('a', list).map((link) => ({
      title: text(link), sub: spaceNames[list.dataset.space], hint: 'Section', icon: $('use', link).getAttribute('href').slice(1),
      words: text($(`${link.hash} h1, ${link.hash} h2`) || link), run: () => go(link.hash),
    }))),
    ...$$('.little-groups dl div').map((item) => ({
      title: text($('dt', item)), sub: text($('dd', item)), icon: 'i-list', words: text(item.closest('section').querySelector('h3')), run: () => go(item, true),
    })),
    ...$$('.grid-list div').map((item) => ({ title: text($('dt', item)), sub: text($('dd', item)), icon: 'i-sparkle', words: 'claude ai', run: () => go(item, true) })),
    ...$$('.faq details').map((item) => ({
      title: text($('summary', item)), sub: text($('p', item)), icon: 'i-question', words: 'question faq',
      run: () => { item.open = true; go(item, true); },
    })),
  ];

  // Every word typed has to be somewhere in the entry; the title counts most.
  function score(entry, words) {
    const title = entry.title.toLowerCase();
    const rest = `${entry.sub || ''} ${entry.words || ''}`.toLowerCase();
    let total = 0;
    for (const word of words) {
      if (title.startsWith(word)) total += 5;
      else if (title.includes(` ${word}`)) total += 4;
      else if (title.includes(word)) total += 3;
      else if (rest.includes(word)) total += 1;
      else return 0;
    }
    return total;
  }

  let results = [];
  let chosen = 0;

  function choose(index) {
    chosen = index;
    $$('li[role="option"]', barList).forEach((row, at) => {
      row.setAttribute('aria-selected', at === index);
      if (at === index) row.scrollIntoView({ block: 'nearest' });
    });
    if (results.length) barInput.setAttribute('aria-activedescendant', `bar-option-${index}`);
    else barInput.removeAttribute('aria-activedescendant');
  }

  function listResults() {
    const words = barInput.value.toLowerCase().split(/\s+/).filter(Boolean);
    // On a small screen the sidebar is a drawer: nothing to hide or move.
    const offered = commands.filter((entry) => !(entry.wide && smallScreen.matches));
    results = words.length
      ? [...offered, ...places].map((entry) => ({ entry, points: score(entry, words) })).filter((found) => found.points > 0)
          .sort((a, b) => b.points - a.points).slice(0, 8).map((found) => found.entry)
      : offered.slice(0, 8);

    barList.replaceChildren(...results.map((entry, index) => {
      const row = document.createElement('li');
      row.id = `bar-option-${index}`;
      row.setAttribute('role', 'option');
      row.innerHTML = `<svg class="icon" aria-hidden="true"><use href="#${entry.icon}"/></svg><span class="bar-text"><span class="bar-title"></span><span class="bar-sub"></span></span><span class="bar-hint"></span>`;
      $('.bar-title', row).textContent = entry.title;
      $('.bar-sub', row).textContent = entry.sub || '';
      $('.bar-hint', row).textContent = entry.hint || '';
      row.addEventListener('pointermove', () => chosen !== index && choose(index));
      row.addEventListener('click', () => runResult(index));
      return row;
    }));
    if (!results.length) {
      const empty = document.createElement('li');
      empty.className = 'bar-empty';
      empty.setAttribute('role', 'presentation');
      empty.textContent = 'Nothing on this page by that name. Try “peek”, “import” or “shortcuts”.';
      barList.append(empty);
    }
    choose(0);
  }

  function runResult(index) {
    const entry = results[index];
    if (!entry) return;
    bar.close();
    entry.run();
  }

  function openBar() {
    if (bar.open) return;
    closeDrawer();
    barInput.value = '';
    bar.showModal();
    listResults();
    barInput.focus();
  }

  barInput.addEventListener('input', listResults);
  barInput.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      if (results.length) choose((chosen + (event.key === 'ArrowDown' ? 1 : -1) + results.length) % results.length);
    } else if (event.key === 'Enter') {
      event.preventDefault();
      runResult(chosen);
    }
  });
  // A click beside the card closes it.
  bar.addEventListener('click', (event) => event.target === bar && bar.close());
  for (const opener of $$('[data-open-bar]')) opener.addEventListener('click', openBar);
  addEventListener('keydown', (event) => {
    const typing = event.target.closest?.('input, textarea, select, [contenteditable]');
    if ((event.key === 'k' && (event.metaKey || event.ctrlKey) && !event.altKey) || (event.key === '/' && !typing && !event.metaKey && !event.ctrlKey && !event.altKey)) {
      event.preventDefault();
      if (bar.open) bar.close();
      else openBar();
    }
  });

  // ---- Start ------------------------------------------------------------------

  showSidebarState();
  updateSpace();
})();
