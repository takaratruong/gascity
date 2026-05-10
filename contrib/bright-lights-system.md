# Bright Lights Gas City System

This branch carries the Bright Lights deployment alongside the Gas City fork so
the engine, research pack, and dashboard can be reviewed from one repository.

## Layout

- `contrib/bright-lights-pack/` is the PackV2 city configuration used by
  `/home/ubuntu/bright-lights`.
- `contrib/gascity-dashboard/` is the React/TypeScript dashboard used by
  `/home/ubuntu/gascity-dashboard`.

Runtime state is intentionally not included. Do not commit `.gc/`, `.beads/`,
logs, generated worktrees, node modules, build output, or experiment artifacts.

## Local Deployment

The live machine paths remain:

- Gas City engine: `/home/ubuntu/gascity`
- Bright Lights pack/runtime: `/home/ubuntu/bright-lights`
- Dashboard: `/home/ubuntu/gascity-dashboard`

To update this branch from the live pack/dashboard, copy source files into the
matching `contrib/` directories and avoid runtime state.
