# WBS Resource Allocation System — Prototype

A click-through prototype of a rebuilt version of the WBS Resource Manager, covering:

- All 12 admin screens (Module Details, Module Allocation, Module Sessions, Module Leaders,
  NonTeaching Roles, Staff Details, Staff Timetable, Course Details, Course Timetables,
  View Reports, Ad Hoc Queries, Publish Details)
- Role-based access: Owner (Resourcing Lead), Head of Department (scoped views), and a
  read-only Staff self-service login
- A demonstration of year-independence: an "academic year" selector instead of a
  separate site/database per year

This is a **design prototype only** — everything runs in your browser with in-memory
sample data. Nothing is saved, there is no real backend, login is simulated via a role
switcher rather than real authentication, and refreshing the page resets all changes.
It exists to validate the interface and permission model before real backend
development starts.

## Viewing it live

This repo is set up for GitHub Pages. Once Pages is enabled (Settings → Pages → Deploy
from branch → `main` → `/ (root)`), it will be live at:

`https://<your-username>.github.io/<repo-name>/`

## Updating it

Any time you (or Claude) produce a new version of `index.html`, commit and push it —
GitHub Pages redeploys automatically within a minute or two, so the same link always
reflects the latest version. No separate hosting step needed.

## What this isn't yet

There is no server, no database, and no real authentication behind this — see the
project's other design notes for the schema and backend plan this prototype is meant
to validate.
