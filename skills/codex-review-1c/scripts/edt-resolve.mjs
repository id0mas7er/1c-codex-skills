#!/usr/bin/env node
// Резолвер пути из дерева EDT в папку объекта на диске (режим edt скилла codex-review-1c).
//
// Использование:
//   node edt-resolve.mjs [--workspace <корень>] <путь> [<путь> ...]
//
// <корень>  — каталог, в котором лежат EDT-проекты (по умолчанию: $EDT_WORKSPACE, иначе текущий
//             каталог). Проектом считается любая подпапка корня с каталогом src/; если src/ есть
//             у самого корня — корень и есть единственный проект.
// <путь>    — путь из дерева EDT с разделителями → -> › > / \ , например
//             "Документы→МойДокумент→Формы→ФормаДокумента"
//             "ВнешниеОбработки→Отчеты→МойВнешнийОтчет",
//             либо голое имя объекта, либо готовый путь на диске.
//
// Выход: абсолютные пути найденных папок (по одному в строке) в stdout.
//        Ненайденные пути — в stderr; код возврата 1, если не найдено ничего.
//        Если имя нашлось в нескольких проектах (основная конфигурация и расширение) —
//        выводятся все варианты: выбор за вызывающим.

import { readdirSync, existsSync, statSync } from "node:fs";
import { join, isAbsolute, resolve } from "node:path";

const args = process.argv.slice(2);
let workspace = process.env.EDT_WORKSPACE || process.cwd();
const inputs = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--workspace" && i + 1 < args.length) workspace = args[++i];
  else inputs.push(args[i]);
}
workspace = resolve(workspace);

const isDir = (p) => {
  try { return statSync(p).isDirectory(); } catch { return false; }
};

function projects() {
  if (isDir(join(workspace, "src"))) return [workspace];
  let entries = [];
  try { entries = readdirSync(workspace, { withFileTypes: true }); } catch { return []; }
  return entries
    .filter((e) => e.isDirectory() && isDir(join(workspace, e.name, "src")))
    .map((e) => join(workspace, e.name));
}

const PROJECTS = projects();

// Узлы дерева EDT, которые не являются папками объектов на диске: виды метаданных,
// структурные узлы и имена проектов. Сравнение без учёта регистра.
const DROP = new Set([
  "рабочая область", "конфигурация", "расширения",
  "документы", "справочники", "отчеты", "отчёты", "обработки",
  "перечисления", "константы", "общие модули", "общиемодули",
  "общие формы", "общиеформы", "общие команды", "общиекоманды",
  "планы видов характеристик", "планывидовхарактеристик",
  "планы счетов", "планысчетов", "планы обмена", "планыобмена",
  "регистры сведений", "регистрысведений",
  "регистры накопления", "регистрынакопления",
  "регистры бухгалтерии", "регистрыбухгалтерии",
  "регистры расчёта", "регистры расчета", "регистрырасчета",
  "бизнес-процессы", "бизнеспроцессы", "задачи", "роли", "подсистемы",
  "формы", "команды", "макеты", "реквизиты", "табличные части",
  "внешние отчёты", "внешние отчеты", "внешниеотчеты",
  "внешние обработки", "внешниеобработки",
  "форма", "модуль", "модуль объекта", "модульобъекта",
  "модуль менеджера", "модульменеджера",
  "реквизиты формы", "команды формы", "элементы формы",
  ...PROJECTS.map((p) => p.split(/[\\/]/).pop().toLowerCase()),
]);

const CONTAINERS = new Set(["формы", "макеты", "команды"]);

const splitPath = (raw) =>
  raw.split(/→|->|›|>|\/|\\/).map((s) => s.trim()).filter(Boolean);

function findDirsByName(bases, name) {
  const out = [];
  for (const base of bases) {
    const stack = [base];
    while (stack.length) {
      const dir = stack.pop();
      let entries;
      try { entries = readdirSync(dir, { withFileTypes: true }); } catch { continue; }
      for (const e of entries) {
        if (!e.isDirectory()) continue;
        const full = join(dir, e.name);
        if (e.name === name) out.push(full);
        else stack.push(full);
      }
    }
  }
  return out;
}

function resolveOne(raw) {
  const direct = isAbsolute(raw) ? raw : join(workspace, raw);
  if (existsSync(direct)) return [direct];

  // Имя проекта в пути сужает поиск до этого проекта. Сегмент сразу после «Формы» / «Макеты» /
  // «Команды» — имя подчинённого объекта (часто «Форма»), его не отбрасываем.
  const segs = splitPath(raw);
  let roots = PROJECTS;
  const kept = [];
  for (let i = 0; i < segs.length; i++) {
    const low = segs[i].toLowerCase();
    const project = PROJECTS.find((p) => p.split(/[\\/]/).pop().toLowerCase() === low);
    if (project) { roots = [project]; continue; }
    const afterContainer = i > 0 && CONTAINERS.has(segs[i - 1].toLowerCase());
    if (afterContainer || !DROP.has(low)) kept.push(segs[i]);
  }
  if (kept.length === 0) return [];

  // Первый значимый сегмент (объект) ищем в src/ проектов, каждый следующий —
  // внутри уже найденных папок.
  let current = findDirsByName(roots.map((p) => join(p, "src")), kept[0]);
  for (let i = 1; i < kept.length && current.length; i++) {
    current = findDirsByName(current, kept[i]);
  }
  return current;
}

if (inputs.length === 0) {
  process.stderr.write("Не передан путь из дерева EDT или имя объекта.\n");
  process.exit(1);
}
if (PROJECTS.length === 0) {
  process.stderr.write(`В ${workspace} не найдено EDT-проектов (подпапок с src/). Укажите --workspace.\n`);
  process.exit(1);
}

const resolved = new Set();
for (const raw of inputs) {
  const hits = resolveOne(raw);
  if (hits.length === 0) process.stderr.write(`Не найдено на диске: ${raw}\n`);
  for (const h of hits) resolved.add(h.replace(/\\/g, "/"));
}
for (const p of resolved) process.stdout.write(p + "\n");
process.exit(resolved.size === 0 ? 1 : 0);
