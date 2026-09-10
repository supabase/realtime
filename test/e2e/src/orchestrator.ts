import { SERVICE_KEY, dbPassword, DB_URL_ARG, env, PARALLEL } from "./context.ts";
import type { SuiteDescriptor } from "./runner.ts";
import { log, printSummary, flushOtel, results, createSuiteTest } from "./runner.ts";
import { setup, cleanup } from "./fixtures.ts";

async function runSuite(d: SuiteDescriptor, testUser: { email: string; password: string }) {
  const { test, drain } = createSuiteTest(d.label, d.parallel);
  await d.run({ testUser, test });
  await drain();
}

// Lives outside runner.ts to avoid an import cycle: fixtures.ts (setup/cleanup) already
// imports `log` from runner.ts, so runner.ts can't import fixtures.ts back.
export async function runSuites(descriptors: SuiteDescriptor[], testCategories: string[] | null) {
  const LOAD_SUITES = descriptors.map((d) => d.name).filter((n) => n.startsWith("load"));
  const FUNCTIONAL_SUITES = descriptors.map((d) => d.name).filter((n) => !n.startsWith("load"));

  const activeCategories = testCategories
    ? testCategories.flatMap((c: string) => {
        if (c === "functional") return FUNCTIONAL_SUITES;
        if (c === "load") return LOAD_SUITES;
        return [c];
      })
    : null;

  if (activeCategories) {
    const unknown = activeCategories.filter((c: string) => !descriptors.some((d) => d.name === c));
    if (unknown.length > 0) {
      const valid = ["functional", "load", ...descriptors.map((d) => d.name)].join(", ");
      log(`Unknown test categories: ${unknown.join(", ")}\nValid categories: ${valid}`);
      process.exit(1);
    }
  }

  const suitesToRun = activeCategories
    ? descriptors.filter((d) => activeCategories.includes(d.name))
    : descriptors;

  const needsDb = suitesToRun.some((d) => d.needsDb);

  if (needsDb && !SERVICE_KEY) {
    console.error("--secret-key is required");
    process.exit(1);
  }

  if (needsDb && env !== "local" && !dbPassword && !DB_URL_ARG) {
    console.error("--db-password is required for staging and prod environments");
    process.exit(1);
  }

  let userId: string | null = null;
  let testUser: { email: string; password: string } = { email: "", password: "" };

  if (needsDb) {
    const setupResult = await setup();
    userId = setupResult.userId;
    testUser = setupResult.testUser;
  }

  const start = performance.now();
  try {
    if (PARALLEL) {
      await Promise.all(suitesToRun.map((d) => runSuite(d, testUser)));
    } else {
      for (const d of suitesToRun) await runSuite(d, testUser);
    }
  } finally {
    if (userId) await cleanup(userId);
  }

  printSummary(performance.now() - start);
  await flushOtel();

  if (results.some((r) => !r.passed)) process.exit(1);
}
