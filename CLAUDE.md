# Working Agreement

- Treat the main session as orchestrator: decompose first, delegate genuine independent research, implementation, and review slices aggressively; retain product, scope, and interface decisions; validate the integrated output once.
- Before any big feature implementation, run the `grilling` skill in rounds until the design-tree frontier is empty and the user confirms shared understanding.
- Make performance priority one. Request performance-reviewer passes for substantial UI, cache, or network work; add deterministic regression contracts where valuable, while keeping noisy network/UI profiling out of per-commit hard gates.
- Native-first: use standard SwiftUI/AppKit components and system materials, checking official Apple documentation before deviating. A custom surface requires explicit user approval and measured need.
- Tooling is mandatory, not advisory. Every file read and every command whose output enters context MUST go through `rtk` (`rtk read`, `rtk grep`/`rtk rg`, `rtk find`, `rtk git`, `rtk err`, `rtk test`) — never `cat`, bare `grep`, or raw command output. Before editing, locate symbols and assess blast radius with `code-review-graph` (`search`, `query`, `impact`, `architecture`); after editing, run `code-review-graph update --brief`, and `code-review-graph build` whenever it reports a branch mismatch. Use `fj` for Forgejo issues. Apply edits with the structural edit tool: `rtk` is a read/output filter and never writes files.
- `AGENTS.md` is a symlink to `CLAUDE.md`. Edit `CLAUDE.md`; never replace either path with a new file or symlink.
- Keep commits atomic and push to `origin` frequently.
