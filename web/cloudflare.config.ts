// reminders.etherlynx.xyz: the passkey page and assetlinks.json (SPEC §9), served as an
// assets-only Worker from ./public. Deploy with `bun run deploy` (runs `cf deploy ./public`).
import { defineConfig } from "cf/config";

export default defineConfig({
	accountId: "8eb17a298fa81dbdc7ce60965e560962", // the "etherlynx" account, which holds etherlynx.xyz
	worker: {
		name: "lynx-reminders-web",
		compatibilityDate: "2026-11-21",
		domains: ["reminders.etherlynx.xyz"],
	},
});
