local active_border_color = "rgb(3FA9F5)"
local active_shadow_color = "rgba(3FA9F566)"
local inactive_border_color = "rgba(6b5a4599)"
local inactive_shadow_color = "rgba(00000077)"

hl.config({
  general = {
    col = {
      active_border = active_border_color,
      inactive_border = inactive_border_color,
    }
  },

  group = {
    col = {
      border_active = active_border_color,
      border_inactive = inactive_border_color,
    },
  },

  decoration = {
    shadow = {
      enabled = true,
      range = 6,
      render_power = 4,
      color = active_shadow_color,
      color_inactive = inactive_shadow_color,
    },
  },
})
