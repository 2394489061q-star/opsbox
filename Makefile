# ==============================================================================
# opsbox —— 常用开发与运维任务
#
# 用法：make help      （help 是默认目标，直接执行 make 也会显示帮助）
#
# 本项目的两个硬性约定，改本文件时请一并遵守：
#   1. 命令行（recipe）必须以 Tab 开头。Makefile 用空格缩进会直接报
#      "missing separator"，且这个错误在编辑器里几乎看不出来。
#   2. 文件必须是 LF 换行。CRLF 会让 \r 混进命令里，同样是 "missing separator"。
#      .gitattributes 已经把 Makefile 固定为 eol=lf。
#
# 可用变量：
#   PREFIX=/usr/local        安装前缀，例如 make install PREFIX=/opt/opsbox
#   DESTDIR=                 打包暂存根目录，例如 make install DESTDIR=/tmp/pkg
# ==============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

PREFIX  ?= /usr/local
DESTDIR ?=
BINDIR     := $(DESTDIR)$(PREFIX)/bin
LIBEXECDIR := $(DESTDIR)$(PREFIX)/lib/opsbox

WORKDIR   := tests/.work
REPORTDIR := reports

# ==============================================================================
# 帮助
# ==============================================================================

help: ## 显示本帮助（默认目标）
	@printf 'opsbox —— 可用命令：\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*## .*$$' $(MAKEFILE_LIST) \
		| LC_ALL=C sort \
		| awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@printf '\n变量：PREFIX=%s  DESTDIR=%s\n' '$(PREFIX)' '$(DESTDIR)'
	@printf '示例：make install PREFIX=/opt/opsbox\n'

# ==============================================================================
# 质量校验
# ==============================================================================

check: ## 跑完整测试套件（等价于 bash tests/run-tests.sh）
	bash tests/run-tests.sh

lint: ## 静态检查：shellcheck（未安装则自动降级为 bash -n）+ 全量 bash -n
	bash scripts/shellcheck.sh
	@set -e; n=0; \
	files="$$(printf '%s\n' opsbox; find . -path './.git' -prune -o -path './tests/.work' -prune -o -type f -name '*.sh' -print | LC_ALL=C sort)"; \
	for f in $$files; do \
		bash -n "$$f" || { printf 'bash -n 失败：%s\n' "$$f" >&2; exit 1; }; \
		n=$$((n + 1)); \
	done; \
	printf 'bash -n 通过：%s 个脚本\n' "$$n"

smoke: ## 在真实系统上跑一次巡检（只读；WARN/CRIT 不会让 make 失败）
	@bash opsbox check -f text; code=$$?; \
	printf '\n冒烟完成：退出码 %s（0=OK 1=WARN 2=CRIT 3=用法错误 4=采集失败）\n' "$$code"

# ==============================================================================
# 测试夹具（手工调试用；跑 check 时会由测试套件自动生成）
# ==============================================================================

fixture-healthy: ## 生成「健康主机」夹具到 tests/.work/healthy
	bash tests/fixtures/build.sh $(WORKDIR)/healthy healthy

fixture-troubled: ## 生成「故障主机」夹具到 tests/.work/troubled
	bash tests/fixtures/build.sh $(WORKDIR)/troubled troubled

# ==============================================================================
# 报告
# ==============================================================================

report: ## 生成 Markdown 巡检报告到 reports/opsbox.report.md
	@mkdir -p '$(REPORTDIR)'
	@bash opsbox check -f md -o '$(REPORTDIR)/opsbox.report.md' --fail-on never
	@printf '报告已写入：%s/opsbox.report.md\n' '$(REPORTDIR)'
	@printf '提示：reports/ 与 *.report.md 已在 .gitignore 中忽略，不会误提交。\n'

# ==============================================================================
# 安装 / 卸载
# ==============================================================================

install: ## 安装到 $(PREFIX)（默认 /usr/local），并在 $(PREFIX)/bin 建立入口
	install -d '$(LIBEXECDIR)/lib' '$(LIBEXECDIR)/modules' '$(LIBEXECDIR)/conf'
	install -m 0755 opsbox '$(LIBEXECDIR)/opsbox'
	install -m 0644 lib/*.sh '$(LIBEXECDIR)/lib/'
	install -m 0644 modules/*.sh '$(LIBEXECDIR)/modules/'
	install -m 0644 conf/opsbox.conf '$(LIBEXECDIR)/conf/opsbox.conf'
	install -d '$(BINDIR)'
	ln -sf '$(PREFIX)/lib/opsbox/opsbox' '$(BINDIR)/opsbox'
	@printf '已安装到：%s\n' '$(LIBEXECDIR)'
	@printf '入口：%s/opsbox（主程序会跟随符号链接定位自己的 lib/ 与 modules/）\n' '$(BINDIR)'
	@printf '本地配置请写在 /etc/opsbox/opsbox.conf，升级时不会被覆盖。\n'

uninstall: ## 卸载 make install 部署的文件（保留 /etc/opsbox 与 ~/.config/opsbox 的配置）
	rm -f '$(BINDIR)/opsbox'
	rm -rf '$(LIBEXECDIR)'
	@printf '已卸载：%s 与 %s/opsbox\n' '$(LIBEXECDIR)' '$(BINDIR)'
	@printf '个人配置未删除：/etc/opsbox/opsbox.conf 与 ~/.config/opsbox/opsbox.conf\n'

# ==============================================================================
# 清理
# ==============================================================================

clean: ## 清理中间产物（tests/.work/ 与 reports/）
	rm -rf '$(WORKDIR)' '$(REPORTDIR)'
	@printf '已清理：%s/ 与 %s/\n' '$(WORKDIR)' '$(REPORTDIR)'

.PHONY: help check lint smoke fixture-healthy fixture-troubled report install uninstall clean
