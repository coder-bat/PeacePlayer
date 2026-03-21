//
//  GenrePickerSheet.swift
//  YTAudioPlayer
//
//  Shared genre picker component
//

import SwiftUI

struct GenrePickerSheet: View {
    let genres: [String]
    @Binding var selectedGenre: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                ForEach(genres, id: \.self) { genre in
                    Button(action: {
                        selectedGenre = genre
                        dismiss()
                    }) {
                        HStack {
                            Text(genre)
                                .foregroundColor(.primary)
                            Spacer()
                            if selectedGenre == genre {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
