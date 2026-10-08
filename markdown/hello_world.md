---
name: Hello World
description: The start of the blog!
slug: hello-world
date: 2026-10-04
timestamp: 1791113140
---

# Hello World

**Welcome** to my blog! I've decided to start blogging to document my coding journey. For more information about me,
visit [my profile](https://frasier.dev).

## Where I'm at

I've spent 2 years in web development, building small tools and front-facing websites for customers.
My largest project so far has been Equity Solar's [VPP Studio](https://vppstudio.equitysolar.com.au),
a small platform for an operator to control, monitor and optimise residential solar batteries.

In my own time, I've been slowly moving down the tech stack.
I've moved from TypeScript and Python to Go, then C, and now Zig.
It's been an enjoyable adventure, and I plan to explore embedded systems next,
now that I've got my hands on an STM32 microcontroller.


```zig

// From the zig docs

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, "Hello, World!\n");
}
```


In my own time, I've been slowly moving down the tech stack.
I've moved from TypeScript and Python to Go, then C, and now Zig.
It's been an enjoyable adventure, and I plan to explore embedded systems next,
now that I've got my hands on an STM32 microcontroller.
