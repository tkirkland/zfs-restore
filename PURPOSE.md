# Purpose

This repository exists to hold a custom disaster-recovery script for the
author's laptop.

It is not meant to be a generic restore tool.

It is not meant to be broadly portable.

It is a purpose-built recovery solution for one machine, one storage design,
and one operator.

## Why It Is So Specific

The storage layout, device choices, pool structure, dataset layout, and boot
arrangement are all specific to the author's system.

That specificity is intentional.

The script is valuable precisely because it is allowed to encode the real
layout directly instead of pretending to be universal.

## Why This Is Better Than A Generic Tool

A generic tool would either:

- fail to capture the exact recovery steps this machine requires
- become more complex than necessary in the name of flexibility
- push critical recovery details back onto the human during a failure event

This project takes the opposite approach:

- encode the known-good layout directly
- automate the known recovery path directly
- verify destructive steps instead of assuming they worked

## Practical Intent

The intent is to preserve the author's recovery knowledge in executable form.

Instead of relying on memory, scraps of notes, or old shell history, the goal
is to have one maintained script that knows how to:

- create the expected backup artifact
- rebuild the storage layout this machine expects
- restore the saved ZFS data
- repair bootability so the restored system can boot again

## Scope

This should be understood as a custom operational tool for the author's own
hardware.

If someone else uses it, they should assume it is wrong for their machine
until they deliberately adapt it.
