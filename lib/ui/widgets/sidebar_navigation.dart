import 'package:flutter/material.dart';
import '../../core/theme.dart';

enum SidebarItem {
  mirrorMode,
  editor,
  zoom,
  screenshot,
  record,
  settings,
  guide,
  about,
}

/// Sleek desktop sidebar navigation with active highlight and hover animations.
class SidebarNavigation extends StatefulWidget {
  final SidebarItem selectedItem;
  final ValueChanged<SidebarItem> onItemSelected;
  final VoidCallback onOpenSettings;
  final VoidCallback? onToggleSidebar;

  const SidebarNavigation({
    super.key,
    this.selectedItem = SidebarItem.mirrorMode,
    required this.onItemSelected,
    required this.onOpenSettings,
    this.onToggleSidebar,
  });

  @override
  State<SidebarNavigation> createState() => _SidebarNavigationState();
}

class _SidebarNavigationState extends State<SidebarNavigation> {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      decoration: const BoxDecoration(
        color: AppleCastTheme.sidebarBackground,
        border: Border(
          right: BorderSide(
            color: AppleCastTheme.sidebarBorder,
            width: 1,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top Brand Header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            child: Row(
              children: [
                InkWell(
                  onTap: widget.onToggleSidebar,
                  borderRadius: BorderRadius.circular(6),
                  child: const Padding(
                    padding: EdgeInsets.all(4.0),
                    child: Icon(
                      Icons.menu_rounded,
                      color: Color(0xFF94A3B8),
                      size: 20,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.asset(
                    'assets/images/brand_logo.png',
                    width: 26,
                    height: 26,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: AppleCastTheme.iconBlue,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.all_inclusive_rounded, color: Colors.white, size: 16),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                const Flexible(
                  child: Text(
                    'InfinityCast',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Primary Navigation Links
          _buildNavItem(
            item: SidebarItem.mirrorMode,
            icon: Icons.keyboard_outlined,
            title: 'Mirror Mode',
          ),
          _buildNavItem(
            item: SidebarItem.editor,
            icon: Icons.edit_outlined,
            title: 'Editor',
          ),
          _buildNavItem(
            item: SidebarItem.zoom,
            icon: Icons.search_rounded,
            title: 'Zoom',
          ),
          _buildNavItem(
            item: SidebarItem.screenshot,
            icon: Icons.camera_alt_outlined,
            title: 'Screenshot',
          ),
          _buildNavItem(
            item: SidebarItem.record,
            icon: Icons.radio_button_checked_rounded,
            title: 'Record',
          ),

          const Spacer(),

          // Bottom Utilities Group
          _buildNavItem(
            item: SidebarItem.settings,
            icon: Icons.settings_outlined,
            title: 'Settings',
            onTapOverride: widget.onOpenSettings,
          ),
          _buildNavItem(
            item: SidebarItem.guide,
            icon: Icons.help_outline_rounded,
            title: 'Guide',
          ),
          _buildNavItem(
            item: SidebarItem.about,
            icon: Icons.info_outline_rounded,
            title: 'About',
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildNavItem({
    required SidebarItem item,
    required IconData icon,
    required String title,
    VoidCallback? onTapOverride,
  }) {
    final bool isActive = widget.selectedItem == item;

    return _SidebarItemTile(
      icon: icon,
      title: title,
      isActive: isActive,
      onTap: () {
        if (onTapOverride != null) {
          onTapOverride();
        } else {
          widget.onItemSelected(item);
        }
      },
    );
  }
}

class _SidebarItemTile extends StatefulWidget {
  final IconData icon;
  final String title;
  final bool isActive;
  final VoidCallback onTap;

  const _SidebarItemTile({
    required this.icon,
    required this.title,
    required this.isActive,
    required this.onTap,
  });

  @override
  State<_SidebarItemTile> createState() => _SidebarItemTileState();
}

class _SidebarItemTileState extends State<_SidebarItemTile> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final Color bgColor = widget.isActive
        ? AppleCastTheme.activeNavBackground
        : (_isHovered ? Colors.white.withValues(alpha: 0.04) : Colors.transparent);

    final Color textColor = widget.isActive
        ? Colors.white
        : (_isHovered ? Colors.white : const Color(0xFF94A3B8));

    final Color iconColor = widget.isActive
        ? Colors.white
        : (_isHovered ? Colors.white : const Color(0xFF718096));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(8),
              border: widget.isActive
                  ? Border.all(
                      color: AppleCastTheme.iconBlue.withValues(alpha: 0.25),
                      width: 1,
                    )
                  : null,
            ),
            child: Row(
              children: [
                Icon(
                  widget.icon,
                  size: 19,
                  color: iconColor,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: textColor,
                      fontSize: 13.5,
                      fontWeight: widget.isActive ? FontWeight.w600 : FontWeight.w500,
                      letterSpacing: -0.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
