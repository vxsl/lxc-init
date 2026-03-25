project('xmonad-wlr', 'c',
  version: '0.1.0',
  meson_version: '>=0.58.0',
  default_options: ['c_std=c11', 'warning_level=2', 'werror=false'],
)

add_global_arguments('-DWLR_USE_UNSTABLE', language: 'c')

cc = meson.get_compiler('c')

wlroots    = dependency('wlroots-0.19')
wayland    = dependency('wayland-server')
xkbcommon  = dependency('xkbcommon')
xcb        = dependency('xcb')
dl         = cc.find_library('dl')

# Main compositor binary
executable('xmonad-wlr',
  'main.c',
  dependencies: [wlroots, wayland, xkbcommon],
  install: true,
  install_dir: get_option('prefix') / 'bin',
)

# LD_PRELOAD shim: strip SubstructureRedirect from wlroots' xwm
shared_library('no-redirect',
  'no-redirect.c',
  dependencies: [xcb, dl],
  install: true,
  install_dir: get_option('prefix') / 'lib',
)
