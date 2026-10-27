These two files are byte-for-byte copies of the Mac application's shipped
`modern_UI/Spektrafilm/Spektrafilm/Resources/DI/` tables at upstream commit
99c2d5c9883be485085895157279cc7c4eaa8db6. Do not rebake or edit them here.
The native image host samples the ProPhoto table for every Cineon view and
copies both original files beside a raw Cineon export. See the canonical
`Canvas/CineonLUT.swift` for their equations and provenance.
