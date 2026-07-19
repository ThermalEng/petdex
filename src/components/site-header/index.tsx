import Image from "next/image";
import Link from "next/link";

import { getLocale, getTranslations } from "next-intl/server";

import { withLocale } from "@/lib/locale-routing";

import { AuthBadge } from "@/components/auth/auth-badge";
import { DesktopNav } from "@/components/site-header/desktop-nav";
import { GithubLink } from "@/components/site-header/github-link";
import { MobileNav } from "@/components/site-header/mobile-nav";
import { buildHeaderNav } from "@/components/site-header/nav-items";
import { SubmitLink } from "@/components/site-header/submit-link";
import type { SiteHeaderProps } from "@/components/site-header/types";

import { hasLocale, type Locale } from "@/i18n/config";

export async function SiteHeader({ hideSubmitCta = false }: SiteHeaderProps) {
  const locale = await getLocale();
  const currentLocale: Locale = hasLocale(locale) ? locale : "en";
  const t = await getTranslations("header");
  const common = await getTranslations("common");
  const href = (pathname: string) => withLocale(pathname, currentLocale);
  const nav = buildHeaderNav(href, {
    collections: t("collections"),
    creators: t("creators"),
    requests: t("requests"),
    download: t("download"),
    docs: t("docs"),
    create: t("create"),
    builtWith: t("builtWith"),
    community: t("community"),
    github: common("github"),
    githubRepoAria: t("githubRepoAria"),
  });

  return (
    <header className="sticky top-0 z-40 w-full border-b border-foreground/[0.06] bg-background/88 backdrop-blur-md supports-[backdrop-filter]:bg-background/70">
      <nav className="mx-auto flex h-14 w-full max-w-[1440px] items-center justify-between gap-3 px-4 sm:px-5 md:px-8">
        <div className="flex min-w-0 items-center gap-3 lg:gap-5">
          <Link
            href={href("/")}
            prefetch={false}
            aria-label={common("petdexHome")}
            className="inline-flex items-center gap-2 text-foreground"
          >
            <Image
              src="/brand/petdex-app-icon.png"
              alt=""
              width={28}
              height={28}
              className="size-7"
              priority
            />
            <span className="hidden text-[15px] font-semibold sm:inline">
              Petdex
            </span>
          </Link>
          <DesktopNav
            primary={nav.primary}
            secondary={nav.secondary}
            moreLabel={t("explore")}
          />
        </div>

        <div className="flex shrink-0 items-center gap-2">
          <GithubLink item={nav.githubItem} />
          {hideSubmitCta ? null : (
            <SubmitLink
              href={href("/submit")}
              label={t("submitCta")}
              variant="desktop"
            />
          )}
          <MobileNav
            items={nav.allNav}
            githubItem={nav.githubItem}
            submitHref={href("/submit")}
            submitLabel={t("submitCta")}
            openMenuLabel={t("openMenu")}
            hideSubmitCta={hideSubmitCta}
          />
          <AuthBadge compact />
        </div>
      </nav>
    </header>
  );
}
