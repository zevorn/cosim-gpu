// SPDX-License-Identifier: Apache-2.0

//! Plans and supervises co-simulation sessions on the local system.
//!
//! [`plan`] resolves a validated topology against [`ExecEnv`] and a
//! [`SessionLayout`]. [`run`] executes the plan: every resource it creates
//! has one owner in the session, processes start in dependency order and
//! stop in reverse order, and the result is a [`Verdict`]. [`clean`] removes
//! resources left by a launcher that was killed or exited abnormally.

mod assets;
mod disk;
mod env;
mod images;
mod layout;
mod manifest;
mod node;
mod plan;
mod probe;
mod process;
mod resource;
mod session;

pub use assets::check_assets;
pub use env::{ExecEnv, page_size};
pub use images::{ImageState, inspect_profile, prepare_image_profile};
pub use layout::SessionLayout;
pub use manifest::clean;
pub use plan::{DiskPlan, MachinePlan, NodeRole, Plan, ProcessPlan, plan};
pub use session::{Event, RunOptions, Shutdown, Status, Verdict, run};
