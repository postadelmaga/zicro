# Pinned cross-repository refs

The Z-Scenic backend (`src/window_z.zig`) speaks Z's protocol, which is versioned with
Z, so CI builds against the exact commits named here, never "the default branch":

- `z.ref` — Z commit (branch `zicro-window-protocol`) that has `surface_pointer`,
  `rt.callWordsChecked`, the soft-float runtime and the `-Dzicro-only` KTEST lane.
- `zart.ref` — Zart commit whose `zart_demo` is linked (`zig build zicro-apps`) and
  run (`darwin_zart`) against this Zicro.

Bump them together with a change on the other side. A ref that is not pushed fails
the `check-z` job — on purpose: a skipped integration check must not read as green.

Reproduce locally (repos side by side):

    zig build check-z -Dz-src=../Z
    (cd ../Z && zig build softfloat-test)
    (cd ../Z && zig build zicro-apps -Dzicro-src=../Zicro -Dzart-src=../Zart)
    (cd ../Z && zig build run-x86_64-kvm -Dzicro-src=../Zicro -Dzart-src=../Zart -Dzicro-only -j2 2>&1 | tee boot.log)
    scripts/check-z-session.sh ../Z/boot.log
