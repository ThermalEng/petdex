"use client";

import { ThemeProvider } from "next-themes";

import { AuthIntentProvider } from "@/components/auth/auth-intent";

export function AppProviders({ children }: { children: React.ReactNode }) {
  return (
    <ThemeProvider
      attribute="class"
      defaultTheme="light"
      enableSystem={false}
      disableTransitionOnChange
    >
      <AuthIntentProvider>{children}</AuthIntentProvider>
    </ThemeProvider>
  );
}
