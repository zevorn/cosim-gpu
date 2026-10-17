# Cosim-Specific Codex Review Prompts

Subsystem-specific adversarial review prompts for cosim. Use these when delegating
code review to Codex; keep the generic prompt templates in the main skill.

## Interrupt handler
```
Review this change:
+- Does it correctly route interrupts to the right VMID/PASID?
+- Are TRAP and EOP interrupts handled distinctly?
+- Are cookie fields initialized for all interrupt sources?
+- What happens with concurrent interrupts from different VMIDs?
```

## PM4 packet processor
```
Review this change:
+- Does packet parsing handle all required PM4 opcodes?
+- Are MAP_PROCESS, RUN_LIST, INDIRECT_BUFFER handled correctly?
+- Is VMID/PASID tracking correct across packet boundaries?
+- Are unrecognized packets explicitly rejected?
```

## Cache / TLB
```
Review this change for cache/TLB coherence:
+- Does invalidation cover all required cache levels?
+- Is the scope (single page vs full flush) correct?
+- Are there races between invalidation and concurrent access?
+- Does the change match the corresponding hardware spec?
```

## HSA / Completion signal
```
Review this change:
+- Is done_event scheduled exactly once across all paths?
+- Is memory ownership clear (no leaks, no double-free)?
+- Are interruptible and non-interruptible paths consistent?
+- Does the change handle FullSystem and non-FullSystem modes equivalently?
```

## Common task patterns from cosim sessions

| Task type | Example assignment scope |
|-----------|-------------------------|
| Source edit | "Add `_vmid` field to SDMAQueue, mirror the PM4Queue pattern" |
| Source elimination | "Remove `lastVMID()` calls from pm4_packet_processor.cc, replace with captured/queue-owned VMID" |
| Adversarial review | "Review interrupt_handler.cc CP_EOP changes: VMID routing, cookie init, concurrent VMID handling" |
| Race review | "Review finding F7: `lastVMID()` race between doorbell map and MQD DMA callback. Is the captured_vmid fix complete?" |
| Code investigation | "Search third_party/gem5/src/dev/amdgpu/ for VFIO_USER_REGION_READ handling. Map all code paths." |
