# AI Use Declaration

**Permission:** the course tutor confirmed that AI may be used for the full implementation, provided the student understands every step and declares the use of AI in the documentation.

**AI tool used:** Claude Code (desktop app), Claude Opus 5.5 model.

**What it was used for:** planning the portfolio; writing the Docker setup, SQL, MongoDB, Redis and shell scripts, tests and documentation; running them to capture evidence; and drafting the final documentation. Commits made with the tool carry a `Co-Authored-By` line.

**How the output was reviewed, corrected, tested or verified:**

- Every claim is backed by output from a real run, saved in each portfolio's `evidence/` folder and reproducible with its `run.sh`. No result was typed in by hand.
- Built-in checks make the scripts fail when results are wrong: constraint and rule tests, trial-balance and balance-audit queries, and PostgreSQL/MongoDB count comparisons.
- Figures in the READMEs were cross-checked against the evidence files, and errors found this way were corrected, for example a wrongly reported entry count in Portfolio 4.
- I studied each portfolio's concepts and results from my revision notes, so that I can explain and rerun any part of the work.
