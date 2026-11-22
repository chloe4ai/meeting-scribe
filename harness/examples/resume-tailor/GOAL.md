# GOAL: Tailor a resume to one job description

## Outcome
`out/Resume.docx` and `out/Resume.pdf` cover every keyword in the job description, keep every
fact from the master resume unchanged, have every bullet at the two-line length, and parse the
same way in an applicant tracking system.

## Checks
<!-- Inputs the advisor prepares before round 1:
     out/jd_keywords.txt  -- the JD's keywords, one per line, 'Full Name | ACRONYM' where both count
     out/facts.txt        -- employers, titles, dates, degrees copied from the master resume -->
- id: C1
  desc: Every JD keyword appears in the resume
  cmd: python3 harness/examples/resume-tailor/checks/check_keywords.py --keywords out/jd_keywords.txt --doc out/Resume.docx
  expect: stdout contains PASS
- id: C2
  desc: Every master-resume fact is still there, word for word
  cmd: python3 harness/examples/resume-tailor/checks/check_keywords.py --keywords out/facts.txt --doc out/Resume.docx
  expect: stdout contains PASS
- id: C3
  desc: Every experience bullet is 190-215 characters (two full lines)
  cmd: python3 harness/examples/resume-tailor/checks/check_bullets.py --doc out/Resume.docx --skip-first 6
  expect: stdout contains PASS
- id: C4
  desc: docx and pdf parse to the same words, standard sections, no tables/text boxes/header text
  cmd: python3 harness/examples/resume-tailor/checks/check_ats.py --docx out/Resume.docx --pdf out/Resume.pdf
  expect: stdout contains PASS

## Out of scope
- Inventing experience, changing numbers, or dropping a role to make a check pass.
- Submitting the application or emailing anyone.

## Stop rules
- Pause and ask me if a JD keyword names something I have not done; do not claim it.
- max_rounds: 6
