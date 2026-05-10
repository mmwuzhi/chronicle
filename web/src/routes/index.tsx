import { createFileRoute, Link } from '@tanstack/react-router'

export const Route = createFileRoute('/')({
  component: Index,
})

function Index() {
  return (
    <div className="flex flex-col items-center justify-center min-h-screen gap-4">
      <h1 className="text-4xl font-semibold tracking-tight">Chronicle</h1>
      <p className="text-gray-500">Personal productivity OS</p>
      <div className="flex gap-3 mt-4">
        <Link
          to="/login"
          className="px-4 py-2 rounded-md bg-gray-900 text-white text-sm hover:bg-gray-700 transition-colors"
        >
          Sign in
        </Link>
        <Link
          to="/projects"
          className="px-4 py-2 rounded-md border border-gray-300 text-sm hover:bg-gray-100 transition-colors"
        >
          Projects
        </Link>
      </div>
    </div>
  )
}
