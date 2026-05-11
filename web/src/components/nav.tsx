import { Link } from "@tanstack/react-router";

export function Nav() {
  return (
    <nav className="border-b border-gray-200 bg-white">
      <div className="max-w-3xl mx-auto px-8 h-12 flex items-center gap-6">
        <span className="font-semibold text-sm tracking-tight text-gray-900">
          Chronicle
        </span>
        <div className="flex items-center gap-4 text-sm">
          <Link
            to="/captures"
            className="text-gray-500 hover:text-gray-900 transition-colors [&.active]:text-gray-900 [&.active]:font-medium"
          >
            Captures
          </Link>
          <Link
            to="/tasks"
            className="text-gray-500 hover:text-gray-900 transition-colors [&.active]:text-gray-900 [&.active]:font-medium"
          >
            Tasks
          </Link>
          <Link
            to="/projects"
            className="text-gray-500 hover:text-gray-900 transition-colors [&.active]:text-gray-900 [&.active]:font-medium"
          >
            Projects
          </Link>
        </div>
      </div>
    </nav>
  );
}
