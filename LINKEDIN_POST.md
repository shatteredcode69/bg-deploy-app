🚀 Just shipped a production-grade Blue-Green Deployment system on AWS — and it deploys with absolute zero downtime.

Here's the technical stack I built end-to-end:

𝗪𝗵𝗮𝘁 𝗜 𝗯𝘂𝗶𝗹𝘁:
A Node.js/Express dashboard containerised with Docker (multi-stage build, non-root user) — hosted on AWS EC2, images stored in Amazon ECR, and traffic managed by Nginx.

𝗧𝗵𝗲 𝗰𝗿𝗶𝘁𝗶𝗰𝗮𝗹 𝗰𝗵𝗮𝗹𝗹𝗲𝗻𝗴𝗲𝘀 𝗜 𝘀𝗼𝗹𝘃𝗲𝗱:

① 𝗭𝗲𝗿𝗼 𝗗𝗼𝘄𝗻𝘁𝗶𝗺𝗲 — Instead of stopping the live server to deploy, the new build goes to an idle "slot" (Blue ↔ Green) while production traffic is unaffected. Traffic switches only after health checks pass — via an atomic Nginx symlink replacement.

② 𝗗𝘂𝗮𝗹 𝗛𝗲𝗮𝗹𝘁𝗵 𝗚𝗮𝘁𝗲𝘀 — Before any traffic switch, two checks must pass: Docker's native HEALTHCHECK (container-level) + a curl-based HTTP probe validating the correct environment is running. If either fails, the pipeline aborts and the symlink is never touched.

③ 𝗔𝗪𝗦 𝗜𝗻𝘁𝗲𝗴𝗿𝗮𝘁𝗶𝗼𝗻 — IMDSv2 for instance metadata, ECR for container storage with layer caching, and least-privilege IAM for the CI/CD user.

④ 𝗙𝘂𝗹𝗹𝘆 𝗔𝘂𝘁𝗼𝗺𝗮𝘁𝗲𝗱 — GitHub Actions handles build → push → deploy → verify → switch → cleanup on every push to main. No manual steps.

The architecture I'm most proud of? The deploy script detects the active slot at runtime, pulls the new image, starts the idle container, waits for health, then atomically flips Nginx — all in under 60 seconds.

This is the kind of infrastructure pattern used by teams running at scale. Building it from scratch taught me more about reliability engineering than any course ever could.

Full source code + architecture diagrams in the repo 👇

#DevOps #AWS #Docker #Nginx #GitHubActions #CloudEngineering #ZeroDowntime #BlueGreen #CI_CD #SoftwareEngineering
